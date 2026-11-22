require "test_helper"

class AiRun::UsageTest < ActiveSupport::TestCase
  include AiRunTestHelper

  test "a result's tokens are the sum over modelUsage and its model the costliest" do
    totals = cli_usage.totals
    assert_equal 15, totals[:input_tokens]
    assert_equal 120, totals[:output_tokens]
    assert_equal 500, totals[:cache_write_tokens]
    assert_equal 1000, totals[:cache_read_tokens]
    assert_equal BigDecimal("0.5"), totals[:cost_usd]
    assert_equal "claude-opus-5", totals[:model]
    assert_equal "s1", totals[:claude_session_id]
    assert_equal 2, totals[:model_usage].size
  end

  test "without a result, tokens come from assistant messages, last usage per message id, and cost is nil" do
    usage = AiRun::Usage.new
    usage.see({ "type" => "system", "subtype" => "init", "session_id" => "s9" })
    usage.see(assistant("m1", input: 3, output: 5, read: 100, write: 10))
    usage.see(assistant("m1", input: 3, output: 40, read: 100, write: 10))
    usage.see(assistant("m2", input: 1, output: 2, read: 200, write: 0))

    totals = usage.totals
    assert_equal 4, totals[:input_tokens]
    assert_equal 42, totals[:output_tokens]
    assert_equal 300, totals[:cache_read_tokens]
    assert_equal 10, totals[:cache_write_tokens]
    assert_nil totals[:cost_usd]
    assert_equal "claude-opus-5", totals[:model]
    assert_equal "s9", totals[:claude_session_id]
    assert usage.any?
  end

  test "a result without modelUsage falls back to its usage block" do
    totals = cli_usage(CLI_RESULT.except("modelUsage")).totals
    assert_equal 2, totals[:input_tokens]
    assert_equal 74, totals[:output_tokens]
    assert_equal 16786, totals[:cache_write_tokens]
    assert_equal 11842, totals[:cache_read_tokens]
  end

  test "a result with no cost leaves the cost unknown" do
    assert_nil cli_usage(CLI_RESULT.except("total_cost_usd")).totals[:cost_usd]
  end

  test "nothing seen is nothing used" do
    usage = AiRun::Usage.new
    usage.see(:tick)
    usage.see("not an event")
    refute usage.any?
    assert_equal 0, usage.totals[:input_tokens]
    assert_nil usage.totals[:cost_usd]
  end

  private

  def assistant(id, input:, output:, read:, write:)
    { "type" => "assistant", "message" => { "id" => id, "model" => "claude-opus-5[1m]",
      "usage" => { "input_tokens" => input, "output_tokens" => output, "cache_read_input_tokens" => read, "cache_creation_input_tokens" => write } } }
  end

  # Final review: the CLI's synthetic messages are not a model.
  test "synthetic messages name no model" do
    usage = AiRun::Usage.new
    usage.see({ "type" => "assistant", "message" => { "id" => "m1", "model" => "claude-opus-5", "usage" => { "input_tokens" => 1 } } })
    usage.see({ "type" => "assistant", "message" => { "id" => "m2", "model" => "<synthetic>", "usage" => { "input_tokens" => 0 } } })
    assert_equal "claude-opus-5", usage.totals[:model]

    only = AiRun::Usage.new
    only.see({ "type" => "assistant", "message" => { "id" => "m1", "model" => "<synthetic>", "usage" => { "input_tokens" => 0 } } })
    assert_nil only.totals[:model]
  end

end
