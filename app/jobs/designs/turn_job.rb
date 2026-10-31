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
  # What the publish failed on can name the preview folder, so it goes to the
  # log only.
  PREVIEW_NOT_UPDATED = "Saved, but the preview could not be updated. It refreshes with the next turn.".freeze

  # The system prompt's temp files are named after it, so that the ones killed
  # turns left behind can be found.
  PROMPT_PREFIX = "designs-prompt".freeze

  # How long a first run may have gone on and still be run again as a new
  # session. The CLI fails at once on a session it cannot resume or an id it
  # will not start; a run that failed later had Claude at work, and a whole
  # second run after it could outlast DesignTurn.stale_after, so the screen
  # would show a live turn as interrupted.
  RETRY_WINDOW = 60.seconds

  # A turn that cannot go on. Its message is what the person is told, and
  # nothing more is logged: none of these is Flosis's own failure.
  class Failure < StandardError; end

  class << self
    # Test seams. claude_factory is what a turn talks to Claude through, built
    # from ClaudeCliService's keywords; clock is a monotonic clock in seconds.
    # Set to nil, each is the real one again.
    attr_writer :claude_factory, :clock

    def claude_factory
      @claude_factory || ClaudeCliService.method(:new)
    end

    def clock
      @clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end
  end

  def perform(turn_id)
    turn = DesignTurn.find_by(id: turn_id)
    run(turn) if turn && claim(turn)
  end

  private

  # Only a queued turn is taken, or a running one that is stale. What Solid
  # Queue 1.4 does with a job a deploy interrupts: one released at shutdown
  # comes back at once and finds its turn running but not stale, so it leaves
  # it; one whose worker was killed is marked failed, not delivered again.
  # Either way the cut-off turn stays running until DesignTurn.fail_stale!
  # fails it, and the person retries it. Taking over a stale turn is a belt to
  # that. The row lock keeps two deliveries, or the screen failing the turn as
  # stale, from deciding at the same moment.
  def claim(turn)
    turn.with_lock do
      next false unless turn.queued? || turn.stale?

      turn.start!
      true
    end
  end

  def run(turn)
    sweep_leftovers
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

  # Solid Queue stops a worker with exit!, which runs no ensure: a turn a
  # deploy killed leaves its app copy and its prompt file in the temp folder.
  # Whatever of theirs is older than any turn can run was left that way. A
  # failure here is logged and never stops the turn.
  def sweep_leftovers
    older_than = DesignTurn.stale_after.ago
    Designs::AppCopy.sweep(older_than: older_than)
    Dir.glob(File.join(Dir.tmpdir, "#{PROMPT_PREFIX}*")).each do |path|
      stat = File.lstat(path)
      File.delete(path) if stat.file? && stat.uid == Process.euid && stat.mtime < older_than
    rescue StandardError => e
      Rails.logger.warn("[#{self.class.name}] could not sweep #{path}: #{e.message}")
    end
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] could not sweep the temp folder: #{e.message}")
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
      Designs::AppCopy.open(task.project) do |app|
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
  # leaves it), and fails at once on either. It says so only on its stderr,
  # which ClaudeCliError does not carry, so any failure but a timeout within
  # RETRY_WINDOW is taken for one of these: the turn is run once more as a new
  # session, under a new id the chat keeps, from the branch's last commit
  # rather than from what the failed run left. A run that failed later, or
  # went past its time limit, is not run again.
  def converse(cli, turn, prompt, repo, worktree)
    session = turn.chat_session
    started = self.class.clock.call
    if session.design_turns.where.not(id: turn.id).where.not(started_at: nil).exists?
      cli.resume_session(session_id: session.claude_session_id, prompt: prompt)
    else
      cli.start_session(prompt: prompt, new_session_id: session.claude_session_id)
    end
  rescue ClaudeCliService::TimeoutError
    raise
  rescue ClaudeCliService::ClaudeCliError => e
    raise if self.class.clock.call - started > RETRY_WINDOW.to_f

    log(turn, e, "starting a new Claude session")
    repo.discard!(worktree)
    session.update!(claude_session_id: SecureRandom.uuid)
    cli.start_session(prompt: prompt, new_session_id: session.claude_session_id)
  end

  # The system prompt goes to the CLI as a file in the system's temp folder:
  # in the worktree it would be committed.
  def with_system_prompt(project)
    Tempfile.create([ PROMPT_PREFIX, ".md" ]) do |file|
      file.write(Designs::Prompt.system_text(project: project))
      file.close
      yield file.path
    end
  end

  # The commit's sha (nil for a turn that changed no file), and a note for
  # each step after the commit that failed. Staging, the guard, the commit,
  # the push and the publish run under one hold of the repo's lock: what the
  # guard passed is what is committed, pushed and published. A refused turn
  # does no network work.
  #
  # Once the commit is made, it is the turn's outcome. Failing the turn over a
  # push or a publish would invite a retry that runs Claude again on work
  # already on the branch, so each failure is a note in the chat instead.
  # Every successful turn pushes what origin lacks, an earlier turn's commit
  # included, and a turn that committed or pushed anything is published. The
  # preview is served from this clone, so a commit is published even when its
  # push failed.
  def save(turn, repo, task, worktree, summary)
    slug = Designs::BranchNames.slug(task)
    wip = Designs::BranchNames.wip(task)
    guard = Designs::LeakGuard.new(forbidden_texts: [ Designs::Prompt::BASE ],
                                   secrets: ProjectCredentials.new(task.project).all_secrets)
    message = "#{slug}: #{summary.lines.first.strip.truncate(72)}"
    repo.synchronize do
      result = Designs::Committer.new(repo, guard).commit!(worktree, message: message)
      raise Failure, "Refused: #{result.refusal}" unless result.ok?

      notes = []
      pushed = false
      begin
        if unpushed?(repo, wip)
          repo.push!(wip)
          pushed = true
        end
      rescue StandardError => e
        log(turn, e, "the commit stays on the local branch")
        notes << "Saved, but not pushed to GitHub: #{reason(e)}. It goes out with the next turn."
      end
      if result.sha || pushed
        begin
          Designs::Publisher.new(task.project, repo).publish!(wip, "wip/#{slug}")
        rescue StandardError => e
          log(turn, e, "the preview shows the last turn it took")
          notes << PREVIEW_NOT_UPDATED
        end
      end
      [ result.sha, notes ]
    end
  end

  # Whether the working branch has commits origin lacks: this turn's, or an
  # earlier turn's whose push failed. A branch with no commits of its own (a
  # fresh one whose first turn changed nothing) has nothing to take out.
  def unpushed?(repo, wip)
    repo.head(wip) != repo.remote_head(wip) && repo.commits_ahead(wip).positive?
  end

  # An error's message as a clause: git's ends in a newline, and often in a
  # full stop of its own.
  def reason(error)
    (error.message.presence || error.class.name).strip.delete_suffix(".")
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
