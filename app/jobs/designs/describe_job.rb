require "fileutils"

# Writes a task's next description version from its accepted designs (Accept
# designs, Kacper, 2026-11-21): once a task's thread is merged, its describe
# turn (queued by Designs::Threads.after_merge!) asks Claude, with no tools
# and on the key a design turn uses, for the description with the smallest
# changes that make it say what the design conversation settled. Flosis then
# puts the Designs section under the intro and saves the result as the task's
# current Details version, labelled "Designs accepted".
#
# When Claude fails, times out or answers without a description, the version
# still comes: the description as it was, with the section, and the task's
# modal says the text was not checked. Only a failure to save fails the turn.
class Designs::DescribeJob < ApplicationJob
  queue_as :designs

  # One job at a time per thread, with its turns (Designs::TurnJob's group).
  limits_concurrency to: 1, group: Designs::TurnJob::CONCURRENCY_GROUP, duration: 2.hours,
                     key: ->(turn_id) { Designs::TurnJob.concurrency_key_for_session(DesignTurn.find(turn_id).chat_session) }

  BLOCK = %r{<description>(.*?)</description>}m
  CHANGES = %r{<changes>(.*?)</changes>}m
  # The most of the conversation the prompt carries: its latest messages.
  MESSAGES = 60
  MESSAGE_LIMIT = 1_500

  class << self
    # Test seam: what the job talks to Claude through, built from
    # ClaudeCliService's keywords. Set to nil, it is the real one again.
    attr_writer :claude_factory

    def claude_factory
      @claude_factory || ClaudeCliService.method(:new)
    end
  end

  def perform(turn_id)
    turn = DesignTurn.find_by(id: turn_id)
    return unless turn && claim(turn)

    describe(turn)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] turn #{turn_id}: #{e.class}: #{e.message}")
    fail_turn(turn, "The description could not be written: #{e.message.to_s.truncate(300)}") if turn
  end

  private

  def claim(turn)
    turn.with_lock do
      next false unless turn.queued? || turn.stale?

      turn.start!
      true
    end
  end

  def describe(turn)
    thread = turn.chat_session.design_thread
    task = thread&.task
    return fail_turn(turn, "This thread has no task any more, so there is no description to write.") unless task

    merge = thread.design_merges.newest_first.first
    ahead = Designs::Threads.description_change(thread)
    current = Designs::CurrentDescription.for(task).to_s
    body, changes, fell_back = written(task, thread, current, ahead)
    section = Designs::DesignsSection.build(task)
    text = section ? Designs::DesignsSection.insert(body, section) : body
    key = Designs::ThreadNames.key(task)

    TaskDraft.transaction do
      version = Designs::Threads.next_description_version(task)
      draft = task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "designs", version: version, content: text)
      draft.make_current!
      merge&.update!(description_version: version, description_changes: changes, described_fallback: fell_back)
      # The designs followed the description up to now, so this version is
      # what they saw; a description that moved on without them keeps the
      # record of what they did see, and a reopened thread still offers
      # Update designs for it.
      thread.update!(described_text: text, described_version: "v#{version}") unless ahead
      task.update!(workshop_stage: "details") if task.in_pipeline? && (task.stage_new? || task.stage_briefing?)
      Designs::Threads.note(thread, "#{key}'s description is now v#{version} · designs linked")
      turn.succeed!(commit_sha: nil)
    end
  end

  # [markdown, changes, fell_back]: Claude's description without any Designs
  # section it wrote anyway, and up to three lines of what changed; or, when
  # Claude gave none, the description as it was, as Markdown.
  def written(task, thread, current, ahead)
    prompt = Designs::Prompt.describe_message(task: task, description: Designs::DesignsSection.strip(current),
                                              conversation: conversation(thread), screens: screens(task), ahead: ahead)
    answer = ask(task, prompt)
    body = answer.to_s[BLOCK, 1].to_s.strip
    return [ Designs::DesignsSection.markdown(current), [], true ] if body.empty?

    lines = answer[CHANGES, 1].to_s.lines.map(&:strip).select { |line| line.start_with?("- ") }
    [ Designs::DesignsSection.strip(body), lines.map { |line| line.delete_prefix("- ").strip }.reject(&:empty?).first(3), false ]
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] task #{task.id}: Claude gave no description: #{e.class}: #{e.message}")
    [ Designs::DesignsSection.markdown(current), [], true ]
  end

  def ask(task, prompt)
    FileUtils.mkdir_p(ChatStreaming::NO_CODEBASE_DIR)
    cli = self.class.claude_factory.call(
      codebase_path: ChatStreaming::NO_CODEBASE_DIR.to_s, allowed_tools: [],
      api_key: ProjectCredentials.new(task.project).designs_api_key, max_budget_usd: DesignTurn::DESCRIBE_BUDGET_USD,
      timeout: DesignTurn::DESCRIBE_TIMEOUT_SECONDS, effort: DesignTurn::DESCRIBE_EFFORT
    )
    result = nil
    cli.send_initial_streaming(prompt: prompt) do |line|
      next if line == :keepalive

      data = JSON.parse(line) rescue nil
      result = data if data.is_a?(Hash) && data["type"] == "result"
    end
    result && !result["is_error"] ? result["result"].to_s : nil
  end

  # What the person asked, how the description changed, and what the design
  # AI answered, in order; not a check's lines, which say how screens looked.
  def conversation(thread)
    thread.chat_session.chat_messages.ordered.to_a.filter_map do |message|
      next if message.data.is_a?(Hash) && message.data["check"]

      if message.role == "user" && message.kind.nil?
        "The person: #{message.content.to_s.strip.truncate(MESSAGE_LIMIT)}"
      elsif message.kind == "diff"
        lines = Array(message.data.is_a?(Hash) ? message.data["lines"] : nil).map { |sign, line| "#{sign} #{line}" }
        "The description changed (#{message.content}):\n#{lines.join("\n").truncate(MESSAGE_LIMIT)}"
      elsif message.role == "assistant" && message.kind == "summary"
        "The design AI: #{message.content.to_s.strip.truncate(MESSAGE_LIMIT)}"
      end
    end.last(MESSAGES).join("\n\n")
  end

  def screens(task)
    Designs::AcceptedScreens.new(task).own.map do |screen|
      "- #{screen[:kind] == 'new' ? 'New' : 'Updated'} · #{screen[:context_name]} › #{screen[:name]} " \
        "(designs/#{screen[:context]}/#{screen[:screen]}.html)"
    end.join("\n")
  end

  def fail_turn(turn, message)
    turn.reload
    return unless turn.running?

    turn.fail!(message)
    turn.chat_session.chat_messages.create!(role: "assistant", kind: "error", content: turn.error)
  end
end
