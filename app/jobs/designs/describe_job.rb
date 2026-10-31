require "securerandom"

# Writes a task's Details description from its designs: Claude reads the
# task's worktree (its screens, their contexts and the task's manifest) and
# answers with one <draft>, which becomes the current Details version.
#
# Ruling P4-R1: Claude is given no library text, since the draft goes on to
# the Details description and from there to Jira, where library text must
# never appear; and no app copy, since it describes the designs. It may read
# and nothing else. The worktree is prepared as a turn prepares it, under the
# same per-task lock as the task's turns, so it never reads a turn's half-done
# work. Whatever goes wrong is an error message in the Designs chat, and
# nothing else changes.
class Designs::DescribeJob < ApplicationJob
  queue_as :designs

  limits_concurrency to: 1, group: Designs::TurnJob::CONCURRENCY_GROUP, duration: 2.hours,
                     key: ->(task_id) { self.class.concurrency_key_for(task_id) }

  TOOLS = %w[Read Glob Grep].freeze
  DRAFT = %r{<draft>(.*?)</draft>}m

  NO_DRAFT = "Claude wrote no description from the designs — try again.".freeze

  # Something that stops the description and is told as it is (see TurnJob).
  class Failure < StandardError; end

  def self.concurrency_key_for(task_id)
    Designs::TurnJob.concurrency_key_for(task_id)
  end

  def perform(task_id)
    task = Task.find_by(id: task_id)
    return unless task

    describe(task)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] task #{task_id}: #{e.class}: #{e.message}") unless e.is_a?(Failure)
    note(task, "error", (e.message.presence || e.class.name).truncate(DesignTurn::ERROR_LIMIT)) if task
  end

  private

  def describe(task)
    project = task.project
    key = ProjectCredentials.new(project).designs_api_key
    raise Failure, Designs::TurnJob::NO_KEY unless key

    repo = Designs::Repo.new(project)
    worktree = repo.task_worktree!(task)
    # What a killed turn left in the worktree is no design anyone approved.
    repo.discard!(worktree)

    cli = Designs::TurnJob.claude_factory.call(
      codebase_path: worktree.to_s, allowed_tools: TOOLS, restricted: true, api_key: key,
      max_budget_usd: DesignTurn.turn_budget_usd, timeout: DesignTurn.turn_timeout
    )
    answer = cli.start_session(prompt: prompt(task), new_session_id: SecureRandom.uuid)
    raise Failure, NO_DRAFT if answer[:is_error]

    draft = answer[:response].to_s[DRAFT, 1].to_s.strip
    raise Failure, NO_DRAFT if draft.empty?

    save(task, draft, repo.head(Designs::BranchNames.wip(task)))
  end

  def save(task, draft, described_sha)
    TaskDraft.transaction do
      version = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content: draft)
      version.make_current!
      task.update!(designs_described_sha: described_sha)
      note(task, "system", "Description v#{version.version} written from the designs — open Details.")
    end
  end

  def prompt(task)
    slug = Designs::BranchNames.slug(task)
    agreed = Designs::CurrentDescription.for(task)&.strip.presence || "(nothing yet)"
    questions = open_questions(task)
    questions = questions.empty? ? "(none)" : questions.map { |text| "- #{text.squish}" }.join("\n")
    <<~PROMPT
      You write the Details description of a task from its clickable designs, for the developer who will build it.

      The designs are in your working directory: the screens under designs/, the contexts they can be viewed in (designs/contexts.json), and the task's manifest, designs/tasks/#{slug}.json, which lists the task's screens and the contexts each is shown in. Read them; change nothing.

      ## Task
      #{slug} — #{task.name}

      ## What was agreed so far
      #{agreed}

      ## Questions the design chat left open
      #{questions}

      Answer with exactly one <draft>…</draft> block in Markdown, and nothing outside it, with these sections:

      ## Goal
      ## Screens
      Each screen in the manifest: what it shows and does, and how it differs in each of its contexts.
      ## Acceptance criteria
      ## Open questions
      Every question above, and any the designs raise.
    PROMPT
  end

  # Every question the chat marked as missing. None is taken as answered yet.
  def open_questions(task)
    session = ChatSession.find_active_for(task, purpose: "designs")
    session ? session.chat_messages.where(kind: "missing").ordered.pluck(:content) : []
  end

  def note(task, kind, text)
    ChatSession.find_active_for(task, purpose: "designs")
               &.chat_messages&.create!(role: "assistant", kind: kind, content: text)
  end
end
