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

  def cli_usage(event = CLI_RESULT)
    AiRun::Usage.new.tap { |usage| usage.see(event) }
  end
end
