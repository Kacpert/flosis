require "test_helper"

class AiCostsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @flosis = projects(:jira_project)
    @internal = projects(:plain_project)
    @costs = AiCosts.new(@workspace)
    @now = Time.current
  end

  def run!(price:, area: "pr_reviews", project: @flosis, own_key: false, ran_at: @now, item: nil, status: "succeeded", **rest)
    AiRun.create!(workspace: @workspace, project: project, project_name: project&.name, area: area, automation: "PR review",
                  status: status, ran_at: ran_at, own_key: own_key, cost_usd: price && price / 1.3, price_usd: price,
                  item_type: item&.class&.polymorphic_name, item_id: item&.id, **rest)
  end

  test "areas and projects add up to the total, own key apart" do
    run!(price: 10, area: "pr_reviews")
    run!(price: 5, area: "task_conversations", project: @internal)
    run!(price: 7, area: "designs", own_key: true)
    run!(price: 3, ran_at: 2.months.ago)

    summary = @costs.month(Date.current)
    assert_equal BigDecimal("15"), summary.total
    assert_equal 2, summary.runs
    assert_equal summary.total, summary.by_area.sum { |_, _, amount| amount }
    assert_equal summary.total, summary.by_project.sum { |_, _, amount| amount }
    assert_equal BigDecimal("7"), summary.own_key_total
    assert_equal 8, summary.by_area.size
    assert_equal [ "Elvium", 1, BigDecimal("10") ], summary.by_project.first
  end

  test "mixed project splits own key from totals" do
    run!(price: 4, area: "designs", own_key: true)
    run!(price: 6, area: "task_conversations")

    summary = @costs.month(Date.current)
    assert_equal [ [ "Elvium", 1, BigDecimal("6") ] ], summary.by_project
    assert_equal [ [ "Elvium", 1, BigDecimal("4") ] ], summary.own_key_projects
    assert_equal BigDecimal("6"), summary.total
  end

  test "deleted item stays in totals" do
    run!(price: 2, item_type: "PrReview", item_id: 0)
    row = @costs.month(Date.current).by_area.find { |area, _, _| area == "pr_reviews" }
    assert_equal [ "pr_reviews", 1, BigDecimal("2") ], row
  end

  test "unknown cost is counted apart and never as zero" do
    run!(price: 2)
    run!(price: nil)
    summary = @costs.month(Date.current)
    assert_equal BigDecimal("2"), summary.total
    assert_equal 1, summary.unknown_runs
    assert_equal 2, summary.runs
  end

  test "running rows are nowhere" do
    run!(price: nil, status: "running")
    assert_equal 0, @costs.month(Date.current).runs
    assert_empty @costs.runs(Date.current).to_a
  end

  test "item_figures sums only the asked area for each item" do
    task = tasks(:jira_task)
    run!(price: 12.40, area: "task_conversations", item: task, ran_at: 2.months.ago)
    run!(price: 3.23, area: "task_conversations", item: task)
    run!(price: 1, area: "estimates", item: task)

    figure = @costs.item_figures([ task ], area: "task_conversations")[[ "Task", task.id ]]
    assert_equal BigDecimal("15.63"), figure.total
    assert_equal BigDecimal("3.23"), figure.this_month
    assert_equal 2, figure.runs
    assert_equal 2, figure.priced_runs
  end

  test "item figures include own key runs at their price" do
    thread_owner = tasks(:jira_task)
    run!(price: 2, area: "designs", item: thread_owner, own_key: true)
    assert_equal BigDecimal("2"), @costs.item_figures([ thread_owner ], area: "designs")[[ "Task", thread_owner.id ]].total
  end

  test "area_months starts with this month even with no runs" do
    run!(price: 9, ran_at: Time.zone.local(2026, 10, 15))
    months = @costs.area_months("pr_reviews")
    assert_equal Date.current.beginning_of_month, months.first.month
    assert_equal 0, months.first.runs
    october = months.find { |m| m.month == Date.new(2026, 10, 1) }
    assert_equal [ BigDecimal("9"), 1 ], [ october.amount, october.runs ]
  end

  test "a run late on the last day of a month in Warsaw belongs to that month" do
    run!(price: 9, ran_at: Time.zone.local(2026, 10, 31, 23, 30))
    october = @costs.area_months("pr_reviews").find { |m| m.month == Date.new(2026, 10, 1) }
    assert_equal 1, october.runs
  end

  test "area_months leaves own key out" do
    run!(price: 9, own_key: true)
    assert_equal 0, @costs.area_months("pr_reviews").first.runs
  end

  test "all_time months carry each month's frozen limit" do
    @workspace.update!(ai_plan: ai_plans(:scale))
    october = Date.new(2026, 10, 1)
    AiMonthLimit.create!(workspace: @workspace, month: october, plan_name: "Starter", limit_usd: 400)
    run!(price: 500, ran_at: Time.zone.local(2026, 10, 10))
    run!(price: 100)

    summary = @costs.all_time
    assert_equal BigDecimal("600"), summary.total
    row = summary.months.find { |month, _, _| month == october }
    assert_equal BigDecimal("400"), row[2].limit_usd
    assert_equal BigDecimal("500"), row[1]
  end

  test "runs lists the month's finished runs newest first" do
    older = run!(price: 1, ran_at: 1.hour.ago)
    newer = run!(price: 1)
    assert_equal [ newer, older ], @costs.runs(Date.current).to_a
    assert_equal [ older ], @costs.runs(Date.current, offset: 1).to_a
  end
end
