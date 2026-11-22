require "test_helper"

class AiCostFormatterTest < ActiveSupport::TestCase
  def fig(total:, month:, priced_runs: 1, runs: 1)
    AiCosts::Figure.new(total: BigDecimal(total), this_month: BigDecimal(month), priced_runs: priced_runs, runs: runs)
  end

  test "item figure: one amount when the month is all of it" do
    assert_equal "$0.68", AiCostFormatter.item(fig(total: "0.68", month: "0.68"))
    assert_equal "$12.40 ($3.23 this month)", AiCostFormatter.item(fig(total: "12.40", month: "3.23"))
    assert_equal "$0.74 (none this month)", AiCostFormatter.item(fig(total: "0.74", month: "0"))
    assert_equal "unknown", AiCostFormatter.item(fig(total: "0", month: "0", priced_runs: 0, runs: 2))
  end

  test "no runs, no figure" do
    assert_nil AiCostFormatter.item(nil)
    assert_nil AiCostFormatter.item(fig(total: "0", month: "0", priced_runs: 0, runs: 0))
  end

  test "money groups thousands and rounds to cents" do
    assert_equal "$1,446.15", AiCostFormatter.money(BigDecimal("1446.149"))
    assert_equal "$0.00", AiCostFormatter.money(nil)
  end

  test "tokens read like the designs" do
    run = AiRun.new(input_tokens: 184_000, output_tokens: 12_400, cache_read_tokens: 90_000, cache_write_tokens: 6_000)
    assert_equal "184k in · 12.4k out · 96k cache", AiCostFormatter.tokens(run)
    assert_equal "2.1M", AiCostFormatter.count(2_100_000)
    assert_equal "0.4k", AiCostFormatter.count(400)
    assert_equal "0", AiCostFormatter.count(0)
    assert_equal "1.2M", AiCostFormatter.count(1_200_000)
  end
end
