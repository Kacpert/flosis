# A design thread's life (Workshop Designs v2): started empty or from a task,
# named by its first message, kept up with its task's description and with
# master, and merged into master by a person or when its task is Done.
#
# Git work runs here, under the project's repo lock, and never while a turn of
# the thread is queued or running: a turn edits the branch's worktree. Claude's
# work is queued as turns (Designs::TurnJob), each with a request: the person's
# message, or one Flosis writes on their behalf (kind "request", not shown).
module Designs::Threads
  class Busy < StandardError; end
  class AlreadyMerged < StandardError; end

  NEW_TITLE = "New thread".freeze
  TITLE_LIMIT = 64
  BUSY = "The design repo is busy — try again in a minute.".freeze
  START_FROM_TASK = <<~REQUEST.freeze
    Design this task. Read its current description and compare it with master. Where a screen already
    covers it, update that screen instead of making a new one; where nothing does, draft it as a new
    section on the screen it belongs to. Say which screens you changed, and what is left to decide.
  REQUEST

  module_function

  # An empty thread: no branch until its first message names one.
  def start!(project:, user:)
    project.design_threads.create!(author: user, title: NEW_TITLE, chat_session: new_session(project, user))
  end

  # "Design with AI" on a task: its thread, named after it, designing at once.
  def start_from_task!(task, user:)
    project = task.project
    base = master_head(project)
    thread = project.design_threads.create!(
      author: user, task: task, title: task.name.truncate(TITLE_LIMIT), chat_session: new_session(project, user),
      branch: Designs::ThreadNames.branch_for(project: project, text: task.name, task: task), base_sha: base,
      described_text: Designs::CurrentDescription.for(task), described_version: version_label(task)
    )
    note(thread, "Thread started from #{Designs::ThreadNames.key(task)} · branch #{thread.branch} created from master #{short(base)}")
    queue_turn(thread, user, START_FROM_TASK, visible: false)
    thread
  end

  # The person's message, with the screen they have open. A fresh thread's
  # first message names its branch and becomes its title.
  def message!(thread, user:, text:, context: nil, screen: nil)
    name!(thread, text) if thread.fresh?
    thread.update!(focus_context: context, focus_screen: screen) if context.present? && screen.present?
    queue_turn(thread, user, text)
  end

  # What changed in the task's description since the thread last designed
  # from it, or nil: { from:, to:, lines: [["-" | "+", line]] }.
  def description_change(thread)
    task = thread.task or return
    now = Designs::CurrentDescription.for(task).to_s
    before = thread.described_text.to_s
    return if now.strip == before.strip

    { from: thread.described_version.presence || "v1", to: version_label(task), lines: line_diff(before, now) }
  end

  def update_description!(thread, user:)
    change = description_change(thread) or return
    key = Designs::ThreadNames.key(thread.task)
    thread.chat_session.chat_messages.create!(
      role: "assistant", kind: "diff", content: "#{key} description changed · #{change[:from]} → #{change[:to]}",
      data: { "from" => change[:from], "to" => change[:to], "lines" => change[:lines] }
    )
    thread.update!(described_text: Designs::CurrentDescription.for(thread.task), described_version: change[:to])
    lines = change[:lines].map { |sign, line| "#{sign} #{line}" }.join("\n")
    queue_turn(thread, user, "#{key}'s description changed (#{change[:from]} → #{change[:to]}):\n#{lines}\n\n" \
                             "Update the designs to match the new description, and say what you changed.", visible: false)
  end

  # The merges that landed on master since the thread's base, newest first.
  def behind(thread)
    return [] if thread.base_sha.blank? || thread.merged?

    shas = Designs::Repo.new(thread.project).master_commits_since(thread.base_sha)
    shas.empty? ? [] : thread.project.design_merges.where(sha: shas).newest_first.to_a
  rescue GitRunner::Error
    []
  end

  # Brings master into the thread's branch. A clean merge is pushed and
  # published at once, and a turn checks the thread's screens against what
  # came in; a collision is left to a turn that resolves it.
  def update_master!(thread, user:)
    merges = behind(thread)
    repo = Designs::Repo.new(thread.project)
    outcome = repo.synchronize(wait: false) do
      refuse_while_turns_run!(thread)
      repo.ensure_clone!
      master = repo.head(Designs::Repo::MASTER)
      if repo.head(thread.branch).nil? && repo.remote_head(thread.branch).nil?
        thread.update!(base_sha: master)
        next :merged
      end

      dir = repo.worktree!(thread.branch, from: thread.base_sha)
      repo.discard!(dir)
      conflicts = repo.merge_master_into!(dir)
      next conflicts.tap { repo.discard!(dir) } if conflicts.any?

      repo.push!(thread.branch) if repo.unpushed?(thread.branch)
      thread.update!(base_sha: master)
      :merged
    end
    publish(thread) if outcome == :merged
    came_in!(thread, merges)
    if outcome == :merged
      queue_turn(thread, user, check_request(merges), visible: false)
    else
      queue_turn(thread, user, DesignTurn.resolve_request(outcome), kind: "resolve_conflicts", visible: false)
    end
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  # Merges the thread into master: a merge commit, pushed, recorded, master
  # published, and the thread read-only after it.
  def merge!(thread, user: nil, how: "manual")
    raise AlreadyMerged, "#{thread.branch} is already merged" if thread.merged?

    repo = Designs::Repo.new(thread.project)
    sha, commits, screens = repo.synchronize(wait: false) do
      raise AlreadyMerged, "#{thread.branch} is already merged" if thread.reload.merged?

      refuse_while_turns_run!(thread)
      repo.ensure_clone!
      repo.worktree!(thread.branch, from: thread.base_sha.presence || Designs::Repo::MASTER)
      counted = repo.commits_ahead(thread.branch)
      changed = changed_screens(repo, thread)
      merged = repo.merge_into_master!(thread.branch, message: "Merge #{thread.branch}: #{thread.title}")
      repo.push!(Designs::Repo::MASTER)
      [ merged, counted, changed ]
    end
    record_merge!(thread, user, how, sha, commits, screens)
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  def short(sha) = sha.to_s.first(7)

  # A task's description version as people know it: its Details draft's,
  # else its brief's.
  def version_label(task)
    version = task.current_detail_draft&.version || task.current_brief&.version
    "v#{version || 1}"
  end

  def line_diff(before, after)
    old_lines = before.lines.map(&:strip).reject(&:empty?)
    new_lines = after.lines.map(&:strip).reject(&:empty?)
    (old_lines - new_lines).map { |line| [ "-", line ] } + (new_lines - old_lines).map { |line| [ "+", line ] }
  end

  def new_session(project, user)
    ChatSession.create!(project: project, workspace: project.workspace, user: user, purpose: "designs_thread",
                        claude_session_id: SecureRandom.uuid, codebase_path: project.designs_dir.to_s.presence || "/tmp")
  end

  def master_head(project)
    repo = Designs::Repo.new(project)
    repo.synchronize do
      repo.ensure_clone!
      repo.head(Designs::Repo::MASTER)
    end
  end

  def name!(thread, text)
    base = master_head(thread.project)
    thread.update!(branch: Designs::ThreadNames.branch_for(project: thread.project, text: text), base_sha: base,
                   title: text.squish.truncate(TITLE_LIMIT))
    note(thread, "Branch #{thread.branch} created from master #{short(base)}")
  end

  def queue_turn(thread, user, text, kind: "design", visible: true)
    turn = DesignTurn.transaction do
      message = thread.chat_session.chat_messages.create!(role: "user", user: user, content: text, kind: (visible ? nil : "request"))
      DesignTurn.create!(chat_session: thread.chat_session, chat_message: message, kind: kind)
    end
    thread.touch
    Designs::TurnJob.perform_later(turn.id)
    turn
  end

  def note(thread, text)
    thread.chat_session.chat_messages.create!(role: "assistant", kind: "system", content: text)
  end

  def came_in!(thread, merges)
    return if merges.empty?

    thread.chat_session.chat_messages.create!(
      role: "assistant", kind: "master", content: "master #{short(merges.last.sha)}… → #{short(merges.first.sha)} brought into this branch",
      data: { "merges" => merges.map { |merge| { "sha" => merge.sha, "title" => merge.title, "changes" => Array(merge.what_changed) } } }
    )
  end

  def check_request(merges)
    came = merges.map { |merge| "- #{merge.title}: #{Array(merge.what_changed).join("; ")}" }.join("\n")
    "Master moved on under this thread, and it has been brought in:\n#{came.presence || "- (nothing recorded)"}\n\n" \
      "Check that the screens this thread changes still fit with what came in, adjust what needs it, and say what you " \
      "adjusted. If nothing needs changing, change nothing and say so."
  end

  def refuse_while_turns_run!(thread)
    raise Busy, BUSY if DesignTurn.active.where(chat_session_id: thread.chat_session_id).exists?
  end

  def changed_screens(repo, thread)
    base = repo.merge_base(thread.branch, Designs::Repo::MASTER) || thread.base_sha
    at = ->(ref) { Designs::Screens.new(paths: repo.ls_files(ref, "designs/"), reader: ->(path) { repo.read_file(ref, path) }) }
    Designs::Changes.new(base: at.call(base), head: at.call(thread.branch)).changed.map { |change| "#{change[:context]}/#{change[:screen]}" }
  end

  def publish(thread, branch: thread.branch, slot: thread.branch, base: thread.base_sha)
    Designs::Publisher.new(thread.project, Designs::Repo.new(thread.project)).publish!(branch, slot, base: base)
  rescue StandardError => e
    Rails.logger.error("[designs] publishing #{branch} failed: #{e.class}: #{e.message}")
  end

  def record_merge!(thread, user, how, sha, commits, screens)
    messages = thread.chat_session.chat_messages
    summary = messages.where(role: "assistant", kind: "summary").ordered.last&.content.presence || thread.title
    asked = messages.where(role: "user", kind: nil).ordered.pluck(:content) + messages.where(kind: "diff").ordered.pluck(:content)
    merge = DesignMerge.create!(
      project: thread.project, design_thread: thread, task: thread.task, user: (user if how == "manual"), sha: sha,
      title: thread.title, branch: thread.branch, how: how, screens: screens, commits: [ commits, 1 ].max,
      summary: summary, what_changed: asked, merged_at: Time.current
    )
    thread.update!(status: "merged", merged_sha: sha, merged_at: merge.merged_at)
    by = how == "manual" ? "by #{user&.name || 'someone'}" : "· #{merge.how_label.delete_prefix('Auto · ')}"
    note(thread, "Merged into master as #{merge.short_sha} #{by}")
    publish(thread, branch: Designs::Repo::MASTER, slot: "master", base: nil)
    Designs::SyncJiraLinksJob.perform_later(thread.task_id) if thread.task&.external_reference.present?
    merge
  end
end
