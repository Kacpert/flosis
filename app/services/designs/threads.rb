# A design thread's life (Workshop Designs v2): started empty or from a task,
# named by its first message, kept up with its task's description and with
# master, its turns stopped or tried again, and merged into master by a
# person or when its task is Done.
#
# Git work runs here, under the project's repo lock, and never while a turn of
# the thread is queued or running: a turn edits the branch's worktree. Claude's
# work is queued as turns (Designs::TurnJob), each with a request: the person's
# message, or one Flosis writes on their behalf (kind "request", not shown).
module Designs::Threads
  class Busy < StandardError; end
  class AlreadyMerged < StandardError; end
  class NothingToMerge < StandardError; end
  class Gone < StandardError; end

  NEW_TITLE = "New thread".freeze
  TITLE_LIMIT = 64
  BUSY = "The design repo is busy — try again in a minute.".freeze
  NOTHING_TO_MERGE = "Nothing to merge yet: this thread has no changes of its own.".freeze
  IMPORTING = "Re-import from staging is still running on this thread. You can talk here and merge it once it finishes.".freeze
  NOT_AN_INSPIRATION = "Inspirations are images, PDFs or notes (.png, .jpg, .gif, .webp, .svg, .pdf, .txt, .md), up to 10 MB each.".freeze
  NO_BRANCH_YET = "Describe the change first: the thread gets its branch, and its inspirations/, with its first message.".freeze
  NOTHING_TO_RETRY = "There is nothing to try again: the thread's last turn did not fail.".freeze
  # A thread's design turns build screens only (Designs::Prompt::SCREENS_ONLY,
  # 2026-11-10): before it is merged, one turn makes components from them.
  COMPONENTS_REQUEST = <<~REQUEST.squish.freeze
    This thread is about to be merged into master. First make components from its screens: where a piece of UI this
    thread added appears more than once, or is what an existing component is for, put it in a component under
    components/<name>/ (its .html, README.md with its guidelines, preview.html with each of its states), or use the
    existing one, and include it in place of every copy. Keep every screen looking and working exactly as it does now,
    and change nothing else. If nothing needs a component, change nothing and say so.
  REQUEST
  # Where a deleted thread's branch waits on GitHub (archive/design/…).
  ARCHIVE = "archive/".freeze
  GONE = "This thread's archive is no longer on GitHub, so it can't come back.".freeze
  INSPIRATION_TYPES = %w[png jpg jpeg gif webp svg pdf txt md].freeze
  INSPIRATION_LIMIT = 10.megabytes
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
    raise Busy, IMPORTING if importing?(thread)

    name!(thread, text) if thread.fresh?
    thread.update!(focus_context: context, focus_screen: screen) if context.present? && screen.present?
    queue_turn(thread, user, text)
  end

  # Try again, under the thread's last turn when it failed: its request runs
  # once more, as a new turn of its kind, so the failed one keeps what it did.
  # Claude resumes the session the failed run is in, and is told that none of
  # its edits were kept (Designs::TurnJob#earlier_failure).
  def retry!(thread, user:)
    raise ArgumentError, "#{thread.branch} is already merged." unless thread.open?
    raise Busy, IMPORTING if importing?(thread)

    DesignTurn.fail_stale!
    turns = DesignTurn.where(chat_session_id: thread.chat_session_id)
    raise Busy, BUSY if turns.active.exists?

    last = turns.order(:id).last
    raise ArgumentError, NOTHING_TO_RETRY unless last&.failed?

    note(thread, "Tried again by #{user&.name || 'someone'}")
    turn = DesignTurn.create!(chat_session: thread.chat_session, chat_message: last.chat_message, kind: last.kind,
                              then_merge: last.then_merge)
    thread.touch
    Designs::TurnJob.perform_later(turn.id)
    turn
  end

  # Stop, on a turn of the thread that waits or runs. One that waits is failed
  # at once, and never starts. One that runs is asked to stop: its job looks
  # every few seconds (Designs::TurnJob#follow), stops Claude and puts the
  # worktree back. The row lock settles a stop and the job's claim of a turn
  # that waits, whichever comes first.
  def stop!(thread, turn_id:, user:)
    turn = DesignTurn.where(chat_session_id: thread.chat_session_id).find(turn_id)
    by = user&.name.presence || "someone"
    turn.with_lock do
      if turn.queued?
        turn.fail!("Stopped by #{by} before it started.")
        thread.chat_session.chat_messages.create!(role: "assistant", kind: "error", content: turn.error)
      elsif turn.running? && turn.stop_requested_at.nil?
        turn.update!(stop_requested_at: Time.current, stop_requested_by: by)
      end
    end
    turn
  end

  # Files a person adds for the AI to borrow from (Workshop Designs v2's
  # "Attach inspiration"): committed to the thread's inspirations/ through the
  # leak guard, pushed and published, and said in the thread.
  def attach!(thread, user:, files:)
    raise Busy, IMPORTING if importing?(thread)
    raise ArgumentError, NO_BRANCH_YET if thread.fresh?

    uploads = Array(files).compact_blank.first(5)
    raise ArgumentError, NOT_AN_INSPIRATION if uploads.empty? || uploads.any? { |file| !inspiration?(file) }

    repo = Designs::Repo.new(thread.project)
    names = repo.synchronize(wait: false) do
      refuse_while_turns_run!(thread)
      repo.ensure_clone!
      dir = repo.worktree!(thread.branch, from: thread.base_sha.presence || Designs::Repo::MASTER)
      repo.follow_origin!(thread.branch)
      repo.discard!(dir)
      FileUtils.mkdir_p(dir.join("inspirations"))
      saved = uploads.map do |file|
        name = ActiveStorage::Filename.new(file.original_filename.to_s).sanitized
        File.binwrite(dir.join("inspirations", name), file.read)
        name
      end
      guard = Designs::LeakGuard.new(secrets: ProjectCredentials.new(thread.project).all_secrets)
      result = Designs::Committer.new(repo, guard).commit!(dir, message: "#{thread.branch.delete_prefix('design/')}: add inspirations")
      raise ArgumentError, "Refused: #{result.refusal}" unless result.ok?

      repo.push!(thread.branch)
      saved
    end
    publish(thread)
    note(thread, "Added to inspirations/: #{names.join(', ')}")
    names
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  def inspiration?(file)
    INSPIRATION_TYPES.include?(File.extname(file.original_filename.to_s).delete_prefix(".").downcase) && file.size.to_i <= INSPIRATION_LIMIT
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

    # A page reads this for every thread it lists: it never waits on a job.
    shas = Designs::Repo.new(thread.project).master_commits_since(thread.base_sha, lock: false)
    shas.empty? ? [] : thread.project.design_merges.where(sha: shas).newest_first.to_a
  rescue GitRunner::Error
    []
  end

  # Brings master into the thread's branch. A clean merge is pushed and
  # published at once, and a turn checks the thread's screens against what
  # came in; a collision is left to a turn that resolves it.
  def update_master!(thread, user:)
    merges = behind(thread)
    from = thread.base_sha
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
      repo.follow_origin!(thread.branch)
      conflicts = repo.merge_master_into!(dir)
      next conflicts.tap { repo.discard!(dir) } if conflicts.any?

      repo.push!(thread.branch) if repo.unpushed?(thread.branch)
      thread.update!(base_sha: master)
      :merged
    end
    publish(thread) if outcome == :merged
    came_in!(thread, merges, from: from)
    if outcome == :merged
      queue_turn(thread, user, check_request(merges), visible: false)
    else
      queue_turn(thread, user, DesignTurn.resolve_request(outcome), kind: "resolve_conflicts", visible: false)
    end
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  # Merges the thread into master: a merge commit, pushed and recorded under
  # the repo's lock, so master never moves on GitHub without its merge in the
  # history; a push GitHub refuses puts master back. Then master is published
  # and the thread is read-only.
  def merge!(thread, user: nil, how: "manual")
    raise AlreadyMerged, "#{thread.branch} is already merged" if thread.merged?

    repo = Designs::Repo.new(thread.project)
    merge = repo.synchronize(wait: false) do
      raise AlreadyMerged, "#{thread.branch} is already merged" if thread.reload.merged?

      refuse_while_turns_run!(thread)
      repo.ensure_clone!
      repo.worktree!(thread.branch, from: thread.base_sha.presence || Designs::Repo::MASTER)
      repo.follow_origin!(thread.branch)
      commits = repo.commits_ahead(thread.branch)
      raise NothingToMerge, NOTHING_TO_MERGE unless commits.positive?

      screens = changed_screens(repo, thread)
      sha = repo.merge_into_master!(thread.branch, message: "Merge #{thread.branch}: #{thread.title}")
      begin
        repo.push!(Designs::Repo::MASTER)
      rescue StandardError
        repo.reset_master!
        raise
      end
      record_merge!(thread, user, how, sha, commits, screens)
    end
    after_merge!(thread)
    merge
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  rescue Designs::Repo::NothingToMerge
    raise NothingToMerge, NOTHING_TO_MERGE
  end

  # Merge to master, which only a person does. A thread whose screens were not
  # made into components since its design turns committed (components_due?)
  # gets a components turn first, which merges it once it succeeds
  # (Designs::TurnJob#merge_after): the turn is returned then, and the merge
  # otherwise.
  def merge_or_prepare!(thread, user:)
    return merge!(thread, user: user) unless components_due?(thread)
    raise AlreadyMerged, "#{thread.branch} is already merged" if thread.merged?

    repo = Designs::Repo.new(thread.project)
    screens = repo.synchronize(wait: false) do
      refuse_while_turns_run!(thread)
      repo.ensure_clone!
      repo.worktree!(thread.branch, from: thread.base_sha.presence || Designs::Repo::MASTER)
      repo.follow_origin!(thread.branch)
      changed_screens(repo, thread)
    end
    note(thread, "Making components from this thread's screens before it merges · #{user&.name || 'someone'}")
    queue_turn(thread, user, components_request(screens), kind: "components", visible: false, then_merge: "manual")
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  # A design turn committed since the thread's last components turn, or the
  # thread has had none. A components turn that failed counts: the chat says
  # why, with Try again, and Merge again is the way past it.
  def components_due?(thread)
    turns = DesignTurn.where(chat_session_id: thread.chat_session_id)
    work = turns.where(kind: "design", status: "succeeded").where.not(commit_sha: nil).maximum(:id) or return false
    turns.where(kind: "components", status: %w[succeeded failed]).where("id > ?", work).none?
  end

  def components_request(screens)
    list = screens.map { |screen| "- designs/#{screen}.html" }.join("\n")
    "#{COMPONENTS_REQUEST}\n\nThe screens this thread changed:\n#{list.presence || '- (none)'}"
  end

  # Deletes a thread nobody wants. Its branch moves to archive/ on GitHub, and
  # the thread waits under Deleted for DesignThread::KEPT, to be restored; a
  # thread nothing was ever committed on goes at once. A merged thread is part
  # of master's history and stays.
  def delete!(thread, user: nil)
    raise AlreadyMerged, "#{thread.branch} is already merged" if thread.merged?

    if thread.fresh?
      refuse_while_turns_run!(thread)
      return destroy_thread!(thread)
    end
    return destroy_thread!(thread) unless archive_branch!(thread)

    thread.update!(status: "deleted", deleted_at: Time.current, task: nil, restore_task_id: thread.task_id)
    note(thread, "Deleted by #{user&.name || 'someone'} · #{thread.branch} kept as #{ARCHIVE}#{thread.branch} " \
                 "for #{DesignThread::KEPT.in_days.to_i} days")
    thread
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  # Brings a deleted thread back while GitHub keeps its archive: the archive is
  # its branch again, on GitHub in one atomic push and here, and the thread is
  # open, with its task unless the task has another thread by now.
  def restore!(thread, user: nil)
    return thread unless thread.deleted?

    repo = Designs::Repo.new(thread.project)
    archive = "#{ARCHIVE}#{thread.branch}"
    repo.synchronize(wait: false) do
      repo.ensure_clone!
      sha = repo.remote_head(archive) or raise Gone, GONE
      repo.push!("#{sha}:refs/heads/#{thread.branch}", ":refs/heads/#{archive}", atomic: true)
      repo.point!(thread.branch, to: sha)
    end
    task = thread.project.tasks.find_by(id: thread.restore_task_id)
    thread.update!(status: "open", deleted_at: nil, restore_task_id: nil, task: (task unless task&.design_thread))
    note(thread, "Restored by #{user&.name || 'someone'} from #{archive}")
    publish(thread)
    thread
  rescue Designs::Repo::Busy
    raise Busy, BUSY
  end

  # A deleted thread past DesignThread::KEPT goes for good: its archive on
  # GitHub, then the thread with its conversation.
  def purge!(thread)
    repo = Designs::Repo.new(thread.project)
    archive = "#{ARCHIVE}#{thread.branch}"
    repo.synchronize do
      repo.ensure_clone!
      repo.push!(":refs/heads/#{archive}") if repo.remote_head(archive)
    end
    destroy_thread!(thread)
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

  def queue_turn(thread, user, text, kind: "design", visible: true, then_merge: nil)
    turn = DesignTurn.transaction do
      message = thread.chat_session.chat_messages.create!(role: "user", user: user, content: text, kind: (visible ? nil : "request"))
      DesignTurn.create!(chat_session: thread.chat_session, chat_message: message, kind: kind, then_merge: then_merge)
    end
    thread.touch
    Designs::TurnJob.perform_later(turn.id)
    turn
  end

  def note(thread, text)
    thread.chat_session.chat_messages.create!(role: "assistant", kind: "system", content: text)
  end

  def came_in!(thread, merges, from:)
    return if merges.empty?

    thread.chat_session.chat_messages.create!(
      role: "assistant", kind: "master", content: "master #{short(from)} → #{short(merges.first.sha)} brought into this branch",
      data: { "merges" => merges.map { |merge| { "sha" => merge.sha, "title" => merge.title, "changes" => Array(merge.what_changed) } } }
    )
  end

  def check_request(merges)
    came = merges.map { |merge| "- #{merge.title}: #{Array(merge.what_changed).join("; ")}" }.join("\n")
    "Master moved on under this thread, and it has been brought in:\n#{came.presence || "- (nothing recorded)"}\n\n" \
      "Check that the screens this thread changes still fit with what came in, adjust what needs it, and say what you " \
      "adjusted. If nothing needs changing, change nothing and say so."
  end

  # A turn a deploy killed is failed first, so it never keeps a thread busy.
  # A re-import's turns run in the setup's own session, so its run counts too.
  def refuse_while_turns_run!(thread)
    DesignTurn.fail_stale!
    raise Busy, IMPORTING if importing?(thread)
    raise Busy, BUSY if DesignTurn.active.where(chat_session_id: thread.chat_session_id).exists?
  end

  # One atomic push, so GitHub never holds the work twice or not at all:
  # archive/<branch> takes the branch's last commit, here or on GitHub, and
  # the branch goes; a branch GitHub keeps keeps the thread whole. Then the
  # branch goes here too, with its preview. False when the branch never had a
  # commit, so there is nothing to keep.
  def archive_branch!(thread)
    repo = Designs::Repo.new(thread.project)
    sha = repo.synchronize(wait: false) do
      refuse_while_turns_run!(thread)
      repo.ensure_clone!
      head = repo.head(thread.branch) || repo.remote_head(thread.branch)
      if head
        refs = [ "+#{head}:refs/heads/#{ARCHIVE}#{thread.branch}" ]
        refs << ":refs/heads/#{thread.branch}" if repo.remote_head(thread.branch)
        repo.push!(*refs, atomic: true)
      end
      path = repo.worktree_path(thread.branch)
      repo.remove_worktree!(path) if path.exist?
      repo.delete_branch!(thread.branch) if repo.head(thread.branch)
      head
    end
    Designs::Publisher.new(thread.project, repo).unpublish!(thread.branch)
    sha.present?
  end

  def destroy_thread!(thread)
    DesignThread.transaction do
      thread.destroy!
      thread.chat_session&.destroy!
    end
  end

  # A re-import a deploy cut off is picked up again (Designs::ResumeSetupsJob),
  # so it holds its thread until it is done or failed.
  def importing?(thread)
    DesignSetup.running.where(design_thread_id: thread.id).exists?
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
    merge
  end

  def after_merge!(thread)
    publish(thread, branch: Designs::Repo::MASTER, slot: "master", base: nil)
    Designs::SyncJiraLinksJob.perform_later(thread.task_id) if thread.task&.external_reference.present?
  end
end
