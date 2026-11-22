# What the Claude CLI reports at the end of a run, and an attribution to hang
# a run on, for the tests that record AI runs (SCRUM-70).
module AiRunTestHelper
  CLI_RESULT = {
    "type" => "result", "subtype" => "success", "session_id" => "s1", "total_cost_usd" => 0.5, "is_error" => false,
    "result" => "Done.",
    "usage" => { "input_tokens" => 2, "output_tokens" => 74, "cache_creation_input_tokens" => 16786, "cache_read_input_tokens" => 11842 },
    "modelUsage" => {
      "claude-opus-5[1m]" => { "inputTokens" => 10, "outputTokens" => 100, "cacheReadInputTokens" => 1000, "cacheCreationInputTokens" => 500, "costUSD" => 0.45 },
      "claude-haiku-5-5" => { "inputTokens" => 5, "outputTokens" => 20, "cacheReadInputTokens" => 0, "cacheCreationInputTokens" => 0, "costUSD" => 0.05 }
    }
  }.freeze

  def ai_attribution(**overrides)
    AiRun::Attribution.new(**{ workspace: workspaces(:one), project: projects(:jira_project), area: "agents",
                               item_label: "Rule · Test", automation: "Test" }.merge(overrides))
  end

  # Claude answers `response` without running, and the attribution each
  # service was built with is kept, in order, for the block to look at.
  def with_attributed_ai(response)
    seen = []
    original = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) do |**_kw|
      seen << @attribution
      { session_id: "s", response: response }
    end
    yield seen
  ensure
    ClaudeCliService.define_method(:start_session, original)
  end

  # A finished run for `item` worth `total` in all, `this_month` of it this
  # month (the rest two months ago), as the item figures read it.
  def priced_runs!(item, area:, total:, this_month:, workspace: workspaces(:one), project: projects(:jira_project))
    base = { workspace: workspace, project: project, area: area, item_type: item.class.polymorphic_name, item_id: item.id,
             automation: "Test", status: "succeeded" }
    earlier = BigDecimal(total.to_s) - BigDecimal(this_month.to_s)
    AiRun.create!(base.merge(ran_at: 2.months.ago, cost_usd: earlier, price_usd: earlier)) if earlier.positive?
    AiRun.create!(base.merge(ran_at: Time.current, cost_usd: this_month, price_usd: this_month)) if BigDecimal(this_month.to_s).positive?
  end

  def show_ai_costs!(user = users(:one))
    user.update!(show_ai_costs: true)
  end

  def cli_usage(event = CLI_RESULT)
    AiRun::Usage.new.tap { |usage| usage.see(event) }
  end
end
