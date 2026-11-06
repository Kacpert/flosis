# What a task started from another task's conversation is handed (the chat's
# "New task"): an AI reads that conversation, with the new task's title and
# description, and writes down what it settled about the new task. The task
# keeps it as #handoff, and every chat on the task reads it
# (ChatStreaming#handoff_section).
class TaskHandoff
  BLOCK = %r{<handoff>(.*?)</handoff>}m

  def initialize(task)
    @task = task
  end

  # Writes the handoff once. Yields :keepalive while the AI works, for a
  # stream to stay open. A run that fails hands over the conversation as it
  # was instead, so nothing said there is lost.
  def write!(&keepalive)
    return unless @task.handoff_pending?

    @task.update!(handoff: handed_over(&keepalive) || as_it_was)
  end

  private

  def conversation
    @task.handoff_chat_session
  end

  def source_name
    @task.spun_off_from&.name || "another task"
  end

  # The AI's handoff, or nil when there is none to keep. Its run needs no
  # tools and no code: everything it reads is in the prompt.
  def handed_over(&keepalive)
    FileUtils.mkdir_p(ChatStreaming::NO_CODEBASE_DIR)
    service = ClaudeCliService.new(codebase_path: ChatStreaming::NO_CODEBASE_DIR.to_s, allowed_tools: [])
    result = nil
    service.send_initial_streaming(prompt: prompt) do |line|
      next keepalive&.call if line == :keepalive

      data = JSON.parse(line) rescue nil
      result = data if data.is_a?(Hash) && data["type"] == "result"
    end
    return nil if result.nil? || result["is_error"]

    text = result["result"].to_s
    block = text[BLOCK, 1]
    block ? block.strip : text.strip.presence
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.warn("[TaskHandoff] Task #{@task.id}: the handoff was not written: #{e.message}")
    nil
  end

  def as_it_was
    <<~TEXT.strip
      (The conversation could not be summarized, so here it is as it was. Take from it only what concerns this task.)

      #{transcript}
    TEXT
  end

  def transcript
    conversation.chat_messages.includes(:user).ordered.map do |message|
      speaker = message.role == "assistant" ? "AI" : (message.user&.name.presence || "The person")
      "**#{speaker}:** #{message.content.strip}"
    end.join("\n\n")
  end

  def prompt
    <<~PROMPT
      # What you are doing

      Someone has been working with an AI on the task «#{source_name}», in the conversation below. Part of what they discussed belongs to another piece of work, so they started a NEW task for it:

      **#{@task.name}**

      #{@task.description.presence || "(no description given)"}

      Hand that new task over. Write down everything the conversation settled that matters for it: decisions, rules, numbers and examples the person gave, constraints, what was left for the new task, and the questions still open. Leave out what concerns only «#{source_name}». Keep the person's own numbers, examples and wording where they matter, and add nothing the conversation does not say.

      The reader is the AI that will gather the new task's details with the person. Write short Markdown bullets under a few plain headings, between <handoff> and </handoff>. If nothing in the conversation concerns the new task, write <handoff></handoff>.

      Everything you need is below: do not use any tools.

      # The task the conversation was about: «#{source_name}»

      #{@task.spun_off_from&.description.presence || "(no description)"}

      # The conversation

      #{transcript}
    PROMPT
  end
end
