require "fileutils"
require "find"
require "open3"
require "securerandom"
require "tempfile"
require "tmpdir"

# Runs one turn of a Designs chat. Claude works on the task's working branch
# in its worktree; then Flosis, never Claude, puts what it left through the
# leak guard, commits, pushes and publishes it, and posts the reply in the chat.
#
# Claude gets file tools only (no Bash, no git, no web), the project's own
# key, a cost cap, a time limit, and the application as a read-only copy of
# what its checkout has committed. A turn starts from its branch's last
# commit. Whatever goes wrong before its own commit is made fails it, on the
# turn and in the chat, and is never re-raised: the worktree is put back, so
# the branch stays where the last good turn left it. Once the commit is made,
# the turn has succeeded, and a push or a publish that fails is a note in the
# chat.
class Designs::TurnJob < ApplicationJob
  queue_as :designs

  # Turns of one task share its worktree and its Claude session, so they run
  # one at a time. The duration only bounds a claim whose run was killed.
  limits_concurrency to: 1, key: ->(turn_id) { DesignTurn.find(turn_id).chat_session.task_id }, duration: 2.hours

  # Reading and writing files, nothing else (Designs::Prompt::BASE tells
  # Claude so).
  TOOLS = %w[Read Glob Grep Edit Write].freeze

  NO_KEY = "This project has no Anthropic API key of its own. Add it in Configuration › AI.".freeze
  NO_ANSWER = "Claude returned no answer — it may have hit the cost cap or the time limit.".freeze

  # A turn that cannot go on. Its message is what the person is told, and
  # nothing more is logged: none of these is Flosis's own failure.
  class Failure < StandardError; end

  class << self
    # Test seam: what a turn talks to Claude through, built from
    # ClaudeCliService's keywords. Set to nil, it is the CLI again.
    attr_writer :claude_factory

    def claude_factory
      @claude_factory || ClaudeCliService.method(:new)
    end
  end

  def perform(turn_id)
    turn = DesignTurn.find_by(id: turn_id)
    run(turn) if turn && claim(turn)
  end

  private

  # Only a queued turn is taken, or a running one that was cut off (a deploy
  # killed its job, and the queue delivered it again). The row lock keeps a
  # second delivery, or the screen failing the turn as stale, from deciding
  # at the same moment.
  def claim(turn)
    turn.with_lock do
      next false unless turn.queued? || turn.stale?

      turn.start!
      true
    end
  end

  def run(turn)
    task = turn.chat_session.task
    project = task.project
    repo = Designs::Repo.new(project)
    key = ProjectCredentials.new(project).designs_api_key
    raise Failure, NO_KEY unless key

    worktree = checkout(repo, task)
    # A turn a deploy killed left its edits here. The person saw it fail, and
    # the next commit must not carry them.
    repo.discard!(worktree)

    answer = ask_claude(turn, repo, worktree, key)
    raise Failure, stopped(answer[:response]) if answer[:is_error]

    output = Designs::TurnOutput.parse(answer[:response])
    raise Failure, NO_ANSWER if output.summary.blank?

    sha, notes = save(turn, repo, task, worktree, output.summary)
    DesignTurn.transaction do
      post_reply(turn.chat_session, output, notes)
      turn.succeed!(commit_sha: sha)
    end
  rescue StandardError => e
    fail_turn(turn, e, repo, worktree)
  end

  # A run the CLI says ended in an error: an API error (an overload past the
  # CLI's own retries, say) comes back as an answer whose text is the error,
  # and Claude may have left half its edits. The cost cap ends a run with no
  # text at all.
  def stopped(text)
    text = text.to_s.strip
    text.empty? ? NO_ANSWER : "Claude stopped with an error: #{text.first(300)}"
  end

  # The task's worktree, made on first use: from its working branch, here or
  # on origin, else as a new branch off the task's approved design when it has
  # one, else off master.
  def checkout(repo, task)
    repo.synchronize do
      repo.ensure_clone!
      repo.worktree!(Designs::BranchNames.wip(task), from: base(repo, task))
    end
  end

  # The task's approved design, here or on origin, else master. worktree!
  # starts a new branch off a local one, and a clone made afresh has none of
  # origin's, so origin's is made local first.
  def base(repo, task)
    design = Designs::BranchNames.design(task)
    return design if repo.head(design)

    approved = repo.remote_head(design)
    return Designs::Repo::MASTER unless approved

    repo.point!(design, to: approved)
    design
  end

  # Claude's answer to the person's request, as the CLI gives it back. Nothing
  # it is given lives in the worktree: the system prompt is a temp file and
  # the app a temp copy, both gone when it is done.
  def ask_claude(turn, repo, worktree, key)
    task = turn.chat_session.task
    prompt = Designs::Prompt.turn_message(task: task, request: turn.chat_message.content)
    with_system_prompt(task.project) do |system_prompt|
      with_app_copy(task.project) do |app|
        cli = self.class.claude_factory.call(
          codebase_path: worktree.to_s, allowed_tools: TOOLS, restricted: true, api_key: key,
          append_system_prompt_file: system_prompt, add_dirs: [ app ].compact,
          max_budget_usd: DesignTurn.turn_budget_usd, timeout: DesignTurn.turn_timeout
        )
        converse(cli, turn, prompt, repo, worktree)
      end
    end
  end

  # The chat's first turn starts its Claude session under the id the chat was
  # made with, and every later one resumes it. Any turn that has started
  # counts, failed and cut-off ones too: each may have started the session.
  #
  # The CLI cannot resume a session whose transcript is gone, nor start one
  # under an id that already has a transcript (a first turn killed by a deploy
  # leaves it). It says so only on its stderr, which ClaudeCliError does not
  # carry, so any failure but a timeout is taken for one of these: the turn is
  # run once more as a new session, under a new id the chat keeps, from the
  # branch's last commit rather than from what the failed run left. A run that
  # went past its time limit had all of it and is not run again.
  def converse(cli, turn, prompt, repo, worktree)
    session = turn.chat_session
    if session.design_turns.where.not(id: turn.id).where.not(started_at: nil).exists?
      cli.resume_session(session_id: session.claude_session_id, prompt: prompt)
    else
      cli.start_session(prompt: prompt, new_session_id: session.claude_session_id)
    end
  rescue ClaudeCliService::TimeoutError
    raise
  rescue ClaudeCliService::ClaudeCliError => e
    log(turn, e, "starting a new Claude session")
    repo.discard!(worktree)
    session.update!(claude_session_id: SecureRandom.uuid)
    cli.start_session(prompt: prompt, new_session_id: session.claude_session_id)
  end

  # The system prompt goes to the CLI as a file in the system's temp folder:
  # in the worktree it would be committed.
  def with_system_prompt(project)
    Tempfile.create([ "designs-prompt", ".md" ]) do |file|
      file.write(Designs::Prompt.system_text(project: project))
      file.close
      yield file.path
    end
  end

  # Claude reads the application through a copy of what its checkout has
  # committed, made for this turn and read-only. Nothing runs in the checkout
  # itself but git archive: it is shared (the features scan pulls in it, and
  # the legacy Elvium project's is a developer's own working copy), and what
  # it does not track (.env, master.key) must never reach Claude, nor through
  # it a pushed design. Without a checkout, or with nothing in it to copy
  # (nothing committed yet), the turn runs without the app.
  #
  # The copy sits in a private folder of its own, removed with it afterwards.
  def with_app_copy(project)
    if (source = project.ai_codebase_path)
      holder = Dir.mktmpdir("designs-app")
      copy = copy_app(source, File.join(holder, "app"))
    else
      Rails.logger.warn("[#{self.class.name}] project #{project.id} has no app checkout of its own, " \
                        "so the turn runs without the app")
    end
    yield copy
  ensure
    remove_copy(holder) if holder
  end

  # The checkout's HEAD unpacked into dir, with plain files and folders only,
  # files 0444 and folders 0555, so Claude's Edit and Write fail on it. nil,
  # with a warning, when it cannot be made.
  def copy_app(source, dir)
    tarball = "#{dir}.tar"
    GitRunner.run!("archive", "--format=tar", "-o", tarball, "HEAD", chdir: source)
    FileUtils.mkdir(dir, mode: 0o700)
    _, error, status = Open3.capture3({ "LC_ALL" => "C" }, "tar", "-xf", tarball, chdir: dir)
    raise "tar could not unpack it: #{error.strip}" unless status.success?

    File.delete(tarball)
    strip_links!(dir)
    seal!(dir)
    dir
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] no copy of #{source} for Claude to read, so the turn runs without the app: " \
                      "#{e.message}")
    nil
  end

  # A link the app's repo tracks would lead Claude's tools out of the copy (to
  # the live checkout's .env, say), and seal! would follow it. Find does not.
  # Find looks at what it yielded once the block is done, so what was deleted
  # is pruned.
  def strip_links!(dir)
    Find.find(dir, ignore_error: false) do |path|
      stat = File.lstat(path)
      next if stat.file? || stat.directory?

      File.unlink(path)
      Find.prune
    end
  end

  def seal!(dir)
    Find.find(dir, ignore_error: false) do |path|
      File.chmod(File.lstat(path).directory? ? 0o555 : 0o444, path)
    end
  end

  # Writable again first: nothing in a folder that cannot be written to can be
  # deleted.
  def remove_copy(holder)
    FileUtils.chmod_R("u+w", holder)
    FileUtils.rm_rf(holder)
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] could not remove #{holder}: #{e.message}")
  end

  # The commit's sha (nil for a turn that changed no file), and a note for
  # each step after the commit that failed. Staging, the guard, the commit,
  # the push and the publish run under one hold of the repo's lock: what the
  # guard passed is what is committed, pushed and published.
  #
  # Once the commit is made, it is the turn's outcome. Failing the turn over a
  # push or a publish would invite a retry that runs Claude again on work
  # already on the branch, so each failure is a note in the chat instead. The
  # next turn's push takes the commit out, and the preview is served from this
  # clone, so it is published even when the push failed.
  def save(turn, repo, task, worktree, summary)
    slug = Designs::BranchNames.slug(task)
    wip = Designs::BranchNames.wip(task)
    guard = Designs::LeakGuard.new(forbidden_texts: [ Designs::Prompt::BASE ],
                                   secrets: ProjectCredentials.new(task.project).all_secrets)
    message = "#{slug}: #{summary.lines.first.strip.truncate(72)}"
    repo.synchronize do
      result = Designs::Committer.new(repo, guard).commit!(worktree, message: message)
      raise Failure, refusal(result.violations) unless result.ok?
      next [ nil, [] ] unless result.sha

      notes = []
      begin
        repo.push!(wip)
      rescue StandardError => e
        log(turn, e, "the commit stays on the local branch")
        notes << "Saved, but not pushed to GitHub: #{reason(e)}. It goes out with the next turn."
      end
      begin
        Designs::Publisher.new(task.project, repo).publish!(wip, "wip/#{slug}")
      rescue StandardError => e
        log(turn, e, "the preview shows the last turn it took")
        notes << "Saved, but the preview could not be updated: #{reason(e)}."
      end
      [ result.sha, notes ]
    end
  end

  # An error's message as a clause: git's ends in a newline, and often in a
  # full stop of its own.
  def reason(error)
    (error.message.presence || error.class.name).strip.delete_suffix(".")
  end

  # A violation names its path and rule, never the text that broke it.
  def refusal(violations)
    "Refused: #{violations.map { |violation| "#{violation.path} #{violation.reason}" }.join("; ")}"
  end

  # The reply as the chat shows it: the summary, then each context Claude
  # added and each question it left open, a message apiece, then Flosis's
  # notes on what did not go out, cut to fit as an error is.
  def post_reply(session, output, notes)
    replies = [ [ "summary", output.summary ] ] +
              output.contexts.map { |text| [ "context", text ] } +
              output.missing.map { |text| [ "missing", text ] } +
              notes.map { |note| [ "system", note.truncate(DesignTurn::ERROR_LIMIT) ] }
    replies.each { |kind, text| session.chat_messages.create!(role: "assistant", kind: kind, content: text) }
  end

  # The worktree goes back to its branch's last commit, the turn keeps the
  # error and the chat says it, as the turn kept it (cut to fit).
  def fail_turn(turn, error, repo, worktree)
    log(turn, error) unless error.is_a?(Failure)
    put_back(turn, repo, worktree) if worktree
    turn.fail!(error.message.presence || error.class.name)
    turn.chat_session.chat_messages.create!(role: "assistant", kind: "error", content: turn.error)
  end

  # A worktree that cannot be put back, its link changed (Repo::Tampered) or
  # git failing in it, is removed instead: no git runs in it again, and the
  # next turn checks the branch out afresh, from its last commit.
  def put_back(turn, repo, worktree)
    repo.discard!(worktree) if worktree.exist?
  rescue StandardError => e
    log(turn, e, "removing its worktree")
    begin
      repo.remove_worktree!(worktree)
    rescue StandardError => e
      log(turn, e)
    end
  end

  def log(turn, error, consequence = nil)
    Rails.logger.error("[#{self.class.name}] turn #{turn.id}: #{error.class}: #{error.message}" \
                       "#{" — #{consequence}" if consequence}")
  end
end
