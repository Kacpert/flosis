# What one Claude CLI run reported using (SCRUM-70), gathered from the events
# it printed. The final result carries the totals and the cost; a run cut off
# before its result keeps the tokens its assistant messages reported on the
# way (each message's latest usage, by message id), and no cost: unknown.
class AiRun::Usage
  attr_reader :result

  def initialize
    @result = nil
    @messages = {}
    @model = nil
    @session_id = nil
  end

  def see(event)
    return unless event.is_a?(Hash)

    @session_id ||= event["session_id"].presence
    case event["type"]
    when "result" then @result = event
    when "assistant"
      message = event["message"]
      return unless message.is_a?(Hash)

      @model = message["model"] if claude_model?(message["model"])
      @messages[message["id"] || @messages.size] = message["usage"] if message["usage"].is_a?(Hash)
    end
  end

  def any?
    @result.present? || @messages.any?
  end

  def totals
    tokens = @result ? result_tokens : message_tokens
    model_usage = @result && @result["modelUsage"].is_a?(Hash) ? @result["modelUsage"] : nil
    cost = @result && @result["total_cost_usd"]
    tokens.merge(
      cost_usd: cost.nil? ? nil : BigDecimal(cost.to_s),
      model: AiModel.normalize_id(model_usage ? model_usage.select { |id, _| claude_model?(id) }.max_by { |_, used| used["costUSD"].to_f }&.first : @model),
      model_usage: model_usage,
      claude_session_id: @result&.dig("session_id").presence || @session_id
    )
  end

  private

  # The CLI's own synthetic messages carry "<synthetic>": not a model.
  def claude_model?(id)
    id.to_s.start_with?("claude-")
  end

  def result_tokens
    by_model = @result["modelUsage"]
    if by_model.is_a?(Hash) && by_model.any?
      sum(by_model.values, "inputTokens", "outputTokens", "cacheCreationInputTokens", "cacheReadInputTokens")
    else
      usage_tokens([ @result["usage"] ].grep(Hash))
    end
  end

  def message_tokens
    usage_tokens(@messages.values)
  end

  def usage_tokens(usages)
    sum(usages, "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
  end

  def sum(rows, input, output, write, read)
    { input_tokens: rows.sum { |row| row[input].to_i },
      output_tokens: rows.sum { |row| row[output].to_i },
      cache_write_tokens: rows.sum { |row| row[write].to_i },
      cache_read_tokens: rows.sum { |row| row[read].to_i } }
  end
end
