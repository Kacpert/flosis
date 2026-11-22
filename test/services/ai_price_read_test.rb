require "test_helper"

# SCRUM-70: the daily read of Anthropic's prices into Models & prices, from
# LiteLLM's public price list (USD per token → USD per 1M tokens).
class AiPriceReadTest < ActiveSupport::TestCase
  PRICES = {
    "claude-opus-5-5" => { "litellm_provider" => "anthropic", "input_cost_per_token" => 1.5e-05, "output_cost_per_token" => 7.5e-05,
                           "cache_creation_input_token_cost" => 1.875e-05, "cache_read_input_token_cost" => 1.5e-06 },
    "claude-haiku-5-5-20260301" => { "litellm_provider" => "anthropic", "input_cost_per_token" => 1.0e-06, "output_cost_per_token" => 5.0e-06 },
    "bedrock/claude-sonnet-5-5" => { "litellm_provider" => "bedrock", "input_cost_per_token" => 9.9e-06 }
  }.freeze

  def read(json = PRICES.to_json)
    AiPriceRead.new(fetch: ->(_url) { json }).call
  end

  test "reads per-1M prices for known models" do
    result = read
    opus = AiModel.find_by!(model_id: "claude-opus-5-5")
    assert_equal BigDecimal("15"), opus.input_usd_per_mtok
    assert_equal BigDecimal("75"), opus.output_usd_per_mtok
    assert_equal BigDecimal("18.75"), opus.cache_write_usd_per_mtok
    assert_equal BigDecimal("1.5"), opus.cache_read_usd_per_mtok
    assert_equal "read", opus.price_source
    assert opus.read_at
    assert_equal({ updated: 2, failed: 1 }, result)
  end

  test "a dated key is found for an undated id" do
    read
    assert_equal BigDecimal("1"), AiModel.find_by!(model_id: "claude-haiku-5-5").input_usd_per_mtok
  end

  test "a model the source lacks keeps its price and is marked failed" do
    AiModel.create!(model_id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", input_usd_per_mtok: 3)
    read
    sonnet = AiModel.find_by!(model_id: "claude-sonnet-5-5")
    assert_equal BigDecimal("3"), sonnet.input_usd_per_mtok, "another provider's entry is not Anthropic's price"
    assert sonnet.read_failed_at
  end

  test "a failed fetch changes no price" do
    AiModel.create!(model_id: "claude-opus-5-5", name: "Claude Opus 5.5", input_usd_per_mtok: 14)
    result = AiPriceRead.new(fetch: ->(_url) { raise SocketError, "offline" }).call
    assert_equal BigDecimal("14"), AiModel.find_by!(model_id: "claude-opus-5-5").input_usd_per_mtok
    assert_equal 0, result[:updated]
    assert AiModel.find_by!(model_id: "claude-opus-5-5").read_failed_at
  end

  test "a typed price is marked by hand until the next successful read" do
    AiModel.create!(model_id: "claude-opus-5-5", name: "Claude Opus 5.5", input_usd_per_mtok: 99, price_source: "hand", hand_set_at: Time.current)
    read
    opus = AiModel.find_by!(model_id: "claude-opus-5-5")
    assert_equal "read", opus.price_source
    assert_equal BigDecimal("15"), opus.input_usd_per_mtok
  end
end
