require "test_helper"

class AiRunTest < ActiveSupport::TestCase
  def run_row(**attrs)
    AiRun.create!({ workspace: workspaces(:one), project: projects(:jira_project), area: "agents",
                    item_label: "Rule · Daily digest", automation: "Daily digest", status: "succeeded",
                    ran_at: Time.current, cost_usd: 1, price_usd: 1.3, margin_percent: 30 }.merge(attrs))
  end

  test "areas keep Consumption's order and words" do
    assert_equal "Task conversations", AiRun::AREAS.values.first
    assert_equal "Chat with AI on a ticket", AiRun::AREAS.values.last
    assert_equal 8, AiRun::AREAS.size
  end

  test "default margin is 30 unless the env says otherwise" do
    assert_equal BigDecimal("30"), AiRun.default_margin_percent
    ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"] = "25"
    assert_equal BigDecimal("25"), AiRun.default_margin_percent
  ensure
    ENV.delete("FLOSIS_DEFAULT_MARGIN_PERCENT")
  end

  test "billable leaves out running and own key; in_month uses Warsaw months" do
    late_october = Time.zone.local(2026, 10, 31, 23, 30)
    counted = run_row(ran_at: late_october)
    run_row(ran_at: late_october, status: "running", cost_usd: nil, price_usd: nil)
    run_row(ran_at: late_october, own_key: true)
    run_row(ran_at: Time.zone.local(2026, 11, 1, 0, 30))

    assert_equal [ counted ], AiRun.billable.in_month(Date.new(2026, 10, 1)).to_a
  end

  test "unknown_cost is a finished run with no cost" do
    unknown = run_row(cost_usd: nil, price_usd: nil)
    run_row(status: "running", cost_usd: nil, price_usd: nil)

    assert_equal [ unknown ], AiRun.unknown_cost.to_a
  end

  test "a run whose item was deleted says so" do
    assert run_row(item_type: "PrReview", item_id: 0).item_deleted?
    refute run_row(item_type: nil, item_id: nil).item_deleted?
  end

  test "deleting a project keeps its runs" do
    project = Project.create!(name: "Gone", workspace: workspaces(:one), color: "#000000", currency: "USD")
    run = run_row(project: project, project_name: "Gone")
    project.destroy!

    run.reload
    assert_nil run.project_id
    assert_equal "Gone", run.project_name
  end

  test "cache tokens are reads and writes together" do
    assert_equal 30, run_row(cache_read_tokens: 10, cache_write_tokens: 20).cache_tokens
  end

  # Kacper, 2026-11-22: the env is set as "30%"; a value that is no number
  # falls back to 30 rather than breaking every run's price.
  test "the default margin reads 30% and ignores a value that is no number" do
    ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"] = "30%"
    assert_equal BigDecimal("30"), AiRun.default_margin_percent
    ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"] = " 25 % "
    assert_equal BigDecimal("25"), AiRun.default_margin_percent
    ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"] = "lots"
    assert_equal BigDecimal("30"), AiRun.default_margin_percent
  ensure
    ENV.delete("FLOSIS_DEFAULT_MARGIN_PERCENT")
  end

end
