require "securerandom"
require "tempfile"
require "tmpdir"

# Runs one turn of a Designs chat. Claude works on the task's working branch
# in its worktree; then Flosis, never Claude, puts what it left through the
# leak guard, commits, pushes and publishes it, and posts the reply in the chat.
#
# Claude gets file tools (no Bash, no git, no web), the project's own key (or,
# for a project without one, the server's Claude login, as every other AI
# feature of Flosis runs today), a cost cap, a time limit, and the application
# as a read-only copy of what its checkout has committed. A setup turn gets, from its subject, a browser on
# the client's test environment instead (an MCP server) and the repositories
# the run cloned, on a setup turn's bounds. A turn starts from its branch's last
# commit. Whatever goes wrong before its own commit is made fails it, on the
# turn and in the chat, and is never re-raised: the worktree is put back, so
# the branch stays where the last good turn left it. Once the commit is made,
# the turn has succeeded, and a push or a publish that fails is a note in the
# chat.
#
# A resolve_conflicts turn ("Update from master" found master changed the same
# files) merges master in again after its clean start. If the merge goes
# through by itself, the branch is brought up to date without Claude;
# otherwise Claude resolves the conflict markers, and the turn fails if any
# are left.
class Designs::TurnJob < ApplicationJob
  queue_as :designs

  # Everything that works in a task's worktree runs one at a time: its turns
  # (which share one Claude session too), writing the description from it
  # and, in v1, describing it and renaming its branches. Solid Queue
  # keys a limit by group and key, and the group defaults to the job's own
  # class, so the three name one group. The duration only bounds a claim
  # whose run was killed.
  CONCURRENCY_GROUP = "designs-task".freeze

  def self.concurrency_key_for(task_id)
    "designs-task-#{task_id}"
  end

  # A setup run's turns hold the project's setup, apart from its tasks.
  def self.concurrency_key_for_session(session)
    return "designs-thread-#{session.design_thread&.id || session.id}" if session.purpose == "designs_thread"

    session.task_id ? concurrency_key_for(session.task_id) : "designs-setup-#{session.project_id}"
  end

  limits_concurrency to: 1, group: CONCURRENCY_GROUP, duration: 2.hours,
                     key: ->(turn_id) { self.class.concurrency_key_for_session(DesignTurn.find(turn_id).chat_session) }

  # Reading and writing files, nothing else (the library's base prompt tells
  # Claude so).
  TOOLS = %w[Read Glob Grep Edit Write].freeze
  # A plan turn reads and answers: it cannot change a file.
  PLAN_TOOLS = %w[Read Glob Grep].freeze

  NO_ANSWER = "Claude returned no answer — it may have hit the cost cap or the time limit.".freeze
  # What the chat says of a turn the cost cap ended just as Claude finished
  # (see answer_text).
  CAPPED = "Reached the turn's cost limit as it finished. Everything it did was kept.".freeze
  # What the publish failed on can name the preview folder, so it goes to the
  # log only.
  PREVIEW_NOT_UPDATED = "Saved, but the preview could not be updated. It refreshes with the next turn.".freeze
  UP_TO_DATE = "Brought up to date with master.".freeze

  # A line git writes into a file whose merge collided. The separator must be
  # the whole line: a longer row of "=" underlines a Markdown heading.
  CONFLICT_MARKER = /^(?:<{7} |>{7} |={7}\r?$)/

  # The system prompt's temp files are named after it, so that the ones killed
  # turns left behind can be found.
  PROMPT_PREFIX = "designs-prompt".freeze

  # How long a first run may have gone on and still be run again as a new
  # session. The CLI fails at once on a session it cannot resume or an id it
  # will not start; a run that failed later had Claude at work, and a whole
  # second run after it could outlast DesignTurn.stale_after, so the screen
  # would show a live turn as interrupted.
  RETRY_WINDOW = 60.seconds

  # How often a running turn looks whether someone asked to stop it, in
  # seconds, besides every time the CLI has been quiet for a while.
  STOP_CHECK_EVERY = 2

  # A turn that cannot go on. Its message is what the person is told, and
  # nothing more is logged: none of these is Flosis's own failure.
  class Failure < StandardError; end

  # A turn someone stopped (Designs::Threads.stop!). Its message says who.
  class Stopped < Failure; end

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
    return unless turn

    run(turn) if claim(turn)
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

  # Everything that differs between a task's turn and a setup run's comes
  # from the subject (Designs::Subject).
  def run(turn)
    sweep_leftovers
    subject = Designs::Subject.for(turn.chat_session)
    return skip_check(turn) if turn.check? && DesignSetup.unit_running?

    repo = Designs::Repo.new(subject.project)
    key = subject.api_key
    worktree = subject.checkout!(repo)
    start = repo.head(subject.wip_branch)
    start_clean(turn, repo, worktree)
    return bring_up_to_date(turn, repo, subject, start) if @conflicts == []

    # The subject composes once, for the prompt and the guard alike (Rulings
    # P3-R1, P5-R4), and the record of what Claude is given is kept before it
    # runs.
    turn.update!(library_version_ids: subject.library_version_ids)
    subject.prepare!
    answer = ask_claude(turn, repo, worktree, key, subject)
    response, capped = answer_text(answer)
    output = Designs::TurnOutput.parse(response)
    raise Failure, NO_ANSWER if output.summary.blank?
    return plan_done(turn, repo, worktree, output, capped) if turn.plan?

    check_resolved!(worktree) if @conflicts
    sha, notes = save(turn, repo, subject, worktree, output.summary)
    notes.unshift(CAPPED) if capped
    subject.after_turn(repo)
    chips = subject.chips(repo, start, sha, move_focus: !turn.check?)
    check = queue = nil
    if check_follows?(turn, subject, sha, chips)
      summary = output.summary
      if DesignSetup.unit_running?
        notes << DesignTurn::CHECK_IMPORTING
      else
        output = Designs::TurnOutput::Result.new(**output.to_h.merge(summary: "#{summary}\n\n#{DesignTurn::CHECKING}"))
        queue = -> { check = Designs::Threads.new_check(subject.thread, after: turn, summary: summary, chips: chips) }
      end
    end
    finish(turn, output, sha, notes, chips, &queue)
    self.class.perform_later(check.id) if check
    # Merge may have been pressed while a check ran (Designs::Threads.
    # merge_after_check!), so the turn is read again.
    merge_after(turn) if turn.reload.then_merge.present?
  rescue StandardError => e
    fail_turn(turn, e, repo, worktree)
    merge_after_failed_check(turn) if turn.check?
  end

  # A thread's design turn that committed screens is checked on screen next
  # (Kacper, 2026-11-21); a plan, a components or a resolving turn, and a
  # check, are not.
  def check_follows?(turn, subject, sha, chips)
    turn.kind == "design" && sha.present? && chips.any? && subject.is_a?(Designs::Subject::ThreadSubject)
  end

  # The import's browser leaves no room for a check's: the chat says so, and
  # the check ends without Claude.
  def skip_check(turn)
    DesignTurn.transaction do
      turn.chat_session.chat_messages.create!(role: "assistant", kind: "system", content: DesignTurn::CHECK_IMPORTING)
      turn.succeed!(commit_sha: nil)
    end
    merge_after(turn) if turn.reload.then_merge.present?
  end

  # A check Merge was waiting on merges its thread whatever stopped it, as the
  # check only adds fixes and none of its edits were kept; unless a new
  # message came first, as the person's turn is next. Logged, never raised:
  # the turn has already failed.
  def merge_after_failed_check(turn)
    return unless turn.reload.then_merge.present?

    thread = turn.chat_session.design_thread or return
    return not_merged(turn, thread, "a new message came first. Merge again once it is done.") if turn.stop_requested_by == DesignTurn::NEW_MESSAGE

    merge_after(turn)
  rescue StandardError => e
    log(turn, e, "the thread is not merged")
  end

  # A plan only reads. The CLI cannot always be held to that (a project on its
  # own key runs it --bare, where Edit stays), so what it changed anyway is
  # put back, and nothing goes out: no commit, push, preview or Jira link.
  def plan_done(turn, repo, worktree, output, capped)
    put_back(turn, repo, worktree)
    finish(turn, output, nil, capped ? [ CAPPED ] : [])
    carry_on(turn, output)
  end

  # A plan that asks nothing goes straight on to design (Kacper, 2026-11-18:
  # "if it has no doubts, it says so and designs"), unless the person has
  # written meanwhile: their turn carries on instead. What stops it is logged,
  # never raised: the plan has succeeded.
  def carry_on(turn, output)
    return if output.missing.any?
    return if DesignTurn.where(chat_session_id: turn.chat_session_id).active.where.not(id: turn.id).exists?

    thread = turn.chat_session.design_thread or return
    Designs::Threads.design_as_planned!(thread, user: turn.chat_message.user)
  rescue StandardError => e
    log(turn, e, "the design does not start on its own")
  end

  # A components turn that Merge queued (Designs::Threads.merge_or_prepare!)
  # merges its thread once it has succeeded, as Merge would have. What stops
  # the merge is said in the chat, and the turn has succeeded all the same.
  # A check merges as Merge does, making components first when they are due.
  def merge_after(turn)
    thread = turn.chat_session.design_thread or return
    if turn.check?
      Designs::Threads.merge_or_prepare!(thread, user: turn.chat_message.user)
    else
      Designs::Threads.merge!(thread, user: turn.chat_message.user, how: turn.then_merge)
    end
  rescue Designs::Threads::AlreadyMerged
    nil
  rescue Designs::Repo::Conflict
    not_merged(turn, thread, "master changed the same lines. Update from master, then merge.")
  rescue Designs::Threads::Busy, Designs::Threads::NothingToMerge, Designs::Repo::Diverged => e
    not_merged(turn, thread, e.message)
  rescue StandardError => e
    log(turn, e, "the thread is not merged")
    not_merged(turn, thread, "#{reason(e).truncate(200)}. Merge it again.")
  end

  # Said in the chat; a note that cannot be posted is logged, never raised:
  # the turn has succeeded.
  def not_merged(turn, thread, why)
    Designs::Threads.note(thread, "Not merged: #{why}")
  rescue StandardError => e
    log(turn, e, "the chat was not told the thread is not merged")
  end

  # Solid Queue stops a worker with exit!, which runs no ensure: a turn a
  # deploy killed leaves its app copy, its prompt file and its MCP config in
  # the temp folder. Whatever of theirs is older than any turn can run (a
  # setup turn's limit is the longest) was left that way. A failure here is
  # logged and never stops the turn.
  def sweep_leftovers
    older_than = [ DesignTurn.stale_after, DesignTurn.setup_stale_after ].max.ago
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

  # The answer's text, and whether the cost cap ended the run just as Claude
  # finished. Claude sees what is left of its budget and wraps up, and the call
  # that writes its answer can cross the cap: the CLI then ends the run as an
  # error with no text. A last message that ends the turn (a whole <summary>,
  # and no tool after it) is the finished answer, and the work is kept. Any
  # other run that ended in an error fails the turn.
  def answer_text(answer)
    return [ answer[:response], false ] unless answer[:is_error]
    raise Failure, stopped(answer[:response]) unless finished_at_cap?(answer)

    [ answer[:final_text], true ]
  end

  def finished_at_cap?(answer)
    answer[:subtype] == "error_max_budget_usd" && !answer[:final_tool_use] &&
      answer[:final_text].to_s.match?(%r{<summary>\s*\S.*?</summary>}m)
  end

  # A run the CLI says ended in an error: an API error (an overload past the
  # CLI's own retries, say) comes back as an answer whose text is the error,
  # and Claude may have left half its edits. The cost cap ends a run with no
  # text at all.
  def stopped(text)
    text = text.to_s.strip
    text.empty? ? NO_ANSWER : "Claude stopped with an error: #{text.first(300)}"
  end

  # A turn starts from its branch's last commit: a turn a deploy killed left
  # its edits here, the person saw it fail, and the next commit must not carry
  # them. A resolve_conflicts turn then merges master in again, and
  # @conflicts names the files that collided ([] when none did): nothing of a
  # merge waits in the worktree between turns, where a turn queued before
  # this one would have committed the markers.
  def start_clean(turn, repo, worktree)
    repo.discard!(worktree)
    @conflicts = repo.merge_master_into!(worktree) if turn.resolve_conflicts?
  end

  # Master went in by itself, so there is nothing for Claude to do. The merge
  # commit goes out as a turn's commit does; master that had nothing new
  # leaves the turn with no commit.
  # Claude is given nothing, so the turn records no library versions (Ruling
  # P3-R2), whatever an earlier attempt recorded.
  def bring_up_to_date(turn, repo, subject, start)
    turn.update!(library_version_ids: [])
    notes = repo.synchronize { send_out(turn, repo, subject) }
    head = repo.head(subject.wip_branch)
    subject.after_turn(repo)
    output = Designs::TurnOutput::Result.new(summary: UP_TO_DATE, contexts: [], missing: [])
    finish(turn, output, (head unless head == start), notes)
  end

  # The reply, the turn's outcome and what the block adds (the check that
  # follows a build) go in together: once the reply shows, the check is
  # already waiting, so the screen keeps polling for it.
  def finish(turn, output, sha, notes, chips = [])
    DesignTurn.transaction do
      post_reply(turn.chat_session, output, notes, chips, check: turn.check?)
      turn.succeed!(commit_sha: sha, proposed: proposal?(turn, output, sha))
      yield if block_given?
    end
  end

  # A design turn that may propose (variant b), changed no file and asked: it
  # waits for the person, as a plan that asked does.
  def proposal?(turn, output, sha)
    turn.kind == "design" && turn.may_propose && sha.nil? && output.missing.any?
  end

  # Every file that collided must be free of conflict markers before the
  # merge is committed. The turn fails otherwise, and putting the worktree
  # back aborts the merge.
  def check_resolved!(worktree)
    left = @conflicts.select { |path| marked?(worktree.join(path)) }
    raise Failure, "Conflict markers are still in: #{left.join(", ")}" if left.any?
  end

  # A file Claude deleted has no markers left in it.
  def marked?(file)
    file.file? && !file.symlink? && file.binread.match?(CONFLICT_MARKER)
  end

  # Claude's answer to the person's request, as the CLI gives it back. Nothing
  # it is given lives in the worktree: the system prompt and the MCP config
  # are temp files and the app a temp copy, all gone when it is done.
  def ask_claude(turn, repo, worktree, key, subject)
    # A resolving turn asks about the files that collide now: master may have
    # moved since "Update from master" named them.
    request = @conflicts ? DesignTurn.resolve_request(@conflicts) : turn.chat_message.content
    # The images sent with the message (Kacper, 2026-11-19): written where the
    # turn may read them, and named in the request for its Read tool.
    images = !@conflicts && turn.chat_message.images.attached? ? ChatImages.write!(turn.chat_message) : []
    request = "#{request}\n\n#{ChatImages.note(images)}" if images.any?
    prompt = [ earlier_failure(turn), subject.turn_message(request, turn: turn, worktree: worktree) ].compact.join("\n\n")
    bounds = bounds(turn, subject)
    with_system_prompt(subject) do |system_prompt|
      with_app(subject, turn) do |app|
        subject.with_mcp(worktree, read_only: turn.plan?, browser: turn.check?) do |mcp_config|
          cli = self.class.claude_factory.call(
            codebase_path: worktree.to_s, allowed_tools: bounds[:allowed], restricted: true, api_key: key,
            append_system_prompt_file: system_prompt,
            add_dirs: [ app, *subject.add_dirs, (ChatImages.dir(turn.chat_session) if images.any?) ].compact,
            max_budget_usd: bounds[:budget], timeout: bounds[:timeout], mcp_config: mcp_config,
            tools: bounds[:tools], effort: bounds[:effort]
          )
          activity = Designs::TurnActivity.new(turn, worktree: worktree, app: app)
          begin
            converse(cli, turn, prompt, repo, worktree) { |event| follow(turn, activity, event) }
          ensure
            activity.save
          end
        end
      end
    end
  end

  # What the CLI is given for the turn's kind: a plan only reads, at a lower
  # effort and on small bounds; a check has the design browser, on its own
  # bounds; every other turn has the subject's.
  def bounds(turn, subject)
    if turn.plan?
      { allowed: PLAN_TOOLS, tools: PLAN_TOOLS, budget: DesignTurn::PLAN_BUDGET_USD, timeout: DesignTurn::PLAN_TIMEOUT_SECONDS,
        effort: DesignTurn::PLAN_EFFORT }
    elsif turn.check?
      { allowed: TOOLS + Designs::Subject::CHECK_TOOLS, tools: TOOLS, budget: DesignTurn::CHECK_BUDGET_USD,
        timeout: DesignTurn::CHECK_TIMEOUT_SECONDS, effort: DesignTurn::CHECK_EFFORT }
    else
      { allowed: subject.tools, tools: subject.tool_set, budget: subject.budget_usd, timeout: subject.timeout, effort: nil }
    end
  end

  # A note for Claude when the turn before this one started and failed: the
  # session holds that run, but the worktree went back to the branch's last
  # commit, so none of its edits are there. A retry, the same message again,
  # is told it is one. A check runs in a session of its own, so it neither
  # gets such a note nor counts for one.
  def earlier_failure(turn)
    return if turn.check?

    before = DesignTurn.where(chat_session_id: turn.chat_session_id, id: ...turn.id).where.not(started_at: nil)
                       .where.not(kind: "check").order(:id).last
    return unless before&.failed?

    again = " This turn is another try at the same request: do it again from the start, with what you learned." if before.chat_message_id == turn.chat_message_id
    "## Note from Flosis\nYour last turn did not finish (#{before.error.to_s.truncate(200)}), and none of its changes " \
      "were kept: the files are as they were before it.#{again}"
  end

  # Each event the CLI streams becomes a step for the chat. Every
  # STOP_CHECK_EVERY seconds, and whenever the CLI has been quiet for a while
  # (:tick), the turn looks whether someone asked to stop it: raising stops
  # the CLI, and fails the turn. The look goes to the database past the query
  # cache, which Solid Queue runs every job with: nothing is written while
  # the CLI is quiet, so the cache would answer every tick as it did the first.
  def follow(turn, activity, event)
    activity.record(event) unless event == :tick
    now = self.class.clock.call
    return unless event == :tick || @stop_checked_at.nil? || now - @stop_checked_at >= STOP_CHECK_EVERY

    @stop_checked_at = now
    asked, by = DesignTurn.uncached { DesignTurn.where(id: turn.id).pick(:stop_requested_at, :stop_requested_by) }
    raise Stopped, DesignTurn.stopped_by(by) if asked
  end

  # The app's checkout, copied for the turn, when the subject reads the app
  # that way; nil otherwise, and for a check, which only looks at designs.
  def with_app(subject, turn, &block)
    subject.app_copy? && !turn.check? ? Designs::AppCopy.open(subject.project, &block) : yield(nil)
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
  # session, under a new id the chat keeps, from a clean start (master merged
  # in again for a resolving turn) rather than from what the failed run left.
  # A run that failed later, or went past its time limit, is not run again.
  #
  # The run streams: each event goes to the block as the CLI prints it.
  def converse(cli, turn, prompt, repo, worktree, &on_event)
    # A check runs in a session of its own, new each time: its screenshots
    # never ride along with the thread's later turns.
    return cli.start_session(prompt: prompt, new_session_id: SecureRandom.uuid, &on_event) if turn.check?

    session = turn.chat_session
    started = self.class.clock.call
    if session.design_turns.where.not(id: turn.id).where.not(started_at: nil).where.not(kind: "check").exists?
      cli.resume_session(session_id: session.claude_session_id, prompt: prompt, &on_event)
    else
      cli.start_session(prompt: prompt, new_session_id: session.claude_session_id, &on_event)
    end
  rescue ClaudeCliService::TimeoutError
    raise
  rescue ClaudeCliService::ClaudeCliError => e
    raise if self.class.clock.call - started > RETRY_WINDOW.to_f

    log(turn, e, "starting a new Claude session")
    start_clean(turn, repo, worktree)
    session.update!(claude_session_id: SecureRandom.uuid)
    cli.start_session(prompt: prompt, new_session_id: session.claude_session_id, &on_event)
  end

  # The system prompt goes to the CLI as a file in the system's temp folder:
  # in the worktree it would be committed.
  def with_system_prompt(subject)
    Tempfile.create([ PROMPT_PREFIX, ".md" ]) do |file|
      file.write(subject.system_text)
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
  # included. Every successful turn whose branch has commits of its own is
  # published, so a preview that a failed publish left stale refreshes with the
  # next turn, even one that only answers a question. The preview is served
  # from this clone, so a commit is published even when its push failed.
  def save(turn, repo, subject, worktree, summary)
    guard = Designs::LeakGuard.new(forbidden_texts: subject.forbidden_texts, secrets: subject.secrets)
    message = "#{subject.slug}: #{summary.lines.first.strip.truncate(72)}"
    repo.synchronize do
      result = Designs::Committer.new(repo, guard).commit!(worktree, message: message)
      raise Failure, "Refused: #{result.refusal}" unless result.ok?

      [ result.sha, send_out(turn, repo, subject) ]
    end
  end

  # Pushes and publishes the working branch, and returns a note for each of
  # the two that failed. What origin lacks is pushed: this turn's commit, or
  # an earlier turn's whose push failed.
  def send_out(turn, repo, subject)
    wip = subject.wip_branch
    notes = []
    begin
      repo.push!(wip) if repo.unpushed?(wip)
    rescue StandardError => e
      log(turn, e, "the commit stays on the local branch")
      notes << "Saved, but not pushed to GitHub: #{reason(e)}. It goes out with the next turn."
    end
    begin
      if repo.commits_ahead(wip).positive?
        subject.refresh_base(repo)
        Designs::Publisher.new(subject.project, repo).publish!(wip, subject.preview_slot, base: subject.publish_base)
      end
    rescue StandardError => e
      log(turn, e, "the preview shows the last turn it took")
      notes << PREVIEW_NOT_UPDATED
    end
    notes
  end

  # An error's message as a clause: git's ends in a newline, and often in a
  # full stop of its own.
  def reason(error)
    (error.message.presence || error.class.name).strip.delete_suffix(".")
  end

  # The reply as the chat shows it: the summary, then each context Claude
  # added and each question it left open, a message apiece, then a setup
  # turn's question for the person and what its update brings in, keeps and
  # replaces (Designs imports), then Flosis's notes on what did not go out,
  # cut to fit as an error is.
  # A design thread's summary carries the screens the turn changed, as chips.
  # A check's reply is marked, so a merge is not summed up by it.
  def post_reply(session, output, notes, chips = [], check: false)
    replies = [ [ "summary", output.summary ] ] +
              output.contexts.map { |text| [ "context", text ] } +
              output.missing.map { |text| [ "missing", text ] } +
              [ output.blocked ].compact.map { |text| [ "blocked", text ] } +
              output.comes_in.map { |text| [ "comes_in", text ] } +
              output.kept.map { |text| [ "kept", text ] } +
              output.replaced.map { |text| [ "replaced", text ] } +
              notes.map { |note| [ "system", note.truncate(DesignTurn::ERROR_LIMIT) ] }
    replies.each do |kind, text|
      data = { "chips" => chips } if kind == "summary" && chips.any?
      data = (data || {}).merge("check" => true) if kind == "summary" && check
      session.chat_messages.create!(role: "assistant", kind: kind, content: text, data: data)
    end
  end

  # The worktree goes back to its branch's last commit, the turn keeps the
  # error and the chat says it, as the turn kept it (cut to fit).
  def fail_turn(turn, error, repo, worktree)
    log(turn, error) unless error.is_a?(Failure)
    put_back(turn, repo, worktree) if worktree
    turn.fail!(error.message.presence || error.class.name)
    if quiet_stop?(turn, error)
      turn.chat_session.chat_messages.create!(role: "assistant", kind: "system", content: DesignTurn::CHECK_STOPPED)
    else
      turn.chat_session.chat_messages.create!(role: "assistant", kind: "error", content: turn.error)
    end
  end

  # A check a new message stopped (Designs::Threads.stop_checks!) says so
  # quietly: the person's turn comes next. One stopped with Stop says who.
  def quiet_stop?(turn, error)
    error.is_a?(Stopped) && turn.check? && DesignTurn.where(id: turn.id).pick(:stop_requested_by) == DesignTurn::NEW_MESSAGE
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
