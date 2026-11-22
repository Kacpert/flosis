require "test_helper"

# SCRUM-70: Consumption — an organization's AI spend against its plan, for
# its administrators only. Prices only: cost and margin are Flosis's.
class Workshop::ConsumptionControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @flosis = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
  end

  def run!(price:, area: "pr_reviews", project: @flosis, own_key: false, ran_at: Time.current, status: "succeeded", **rest)
    cost = price && (own_key ? price : (BigDecimal(price.to_s) / BigDecimal("1.3")).round(6))
    AiRun.create!({ workspace: @workspace, project: project, project_name: project&.name, area: area, automation: "PR review",
                    status: status, ran_at: ran_at, own_key: own_key, cost_usd: cost, price_usd: price,
                    margin_percent: (own_key ? nil : 30), item_label: "#19 Designs: count features" }.merge(rest))
  end

  def text = css_select("main").text.squish.presence || response.body

  test "only organization administrators reach Consumption" do
    get workshop_consumption_path
    assert_response :success

    sign_in_as(users(:two))
    get workshop_consumption_path
    assert_response :not_found
  end

  test "the sidebar offers Consumption to administrators only" do
    get workshop_consumption_path
    assert_select "a[href=?]", workshop_consumption_path, text: /Consumption/

    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_consumption_path, count: 0
  end

  test "a month shows areas and projects that add up to the total" do
    @workspace.update!(ai_plan: ai_plans(:scale), ai_plan_assigned_at: Time.zone.local(2026, 10, 1))
    run!(price: 600)
    run!(price: 242.17, area: "task_conversations", project: projects(:plain_project))
    run!(price: 24.60, area: "designs", own_key: true, project: projects(:other_jira_project))

    get workshop_consumption_path
    assert_response :success
    totals = css_select("[data-consumption-total]").map { |row| row.text.squish }
    assert_equal 2, totals.size
    totals.each { |row| assert_includes row, "$842.17" }
    assert_includes response.body, "of $1,200.00"
    assert_includes response.body, "70% of the limit"
    assert_includes response.body, "$357.83 left"
    assert_includes css_select("[data-plan-card]").text.squish, "Scale · $1,200.00 / month"
    assert_includes css_select("[data-own-key-row]").text, "SecretProject"
    assert_includes css_select("[data-own-key-row]").text, "$24.60"
  end

  test "over the limit says by how much and that nothing was blocked" do
    @workspace.update!(ai_plan: ai_plans(:scale))
    october = Date.new(2026, 10, 1)
    AiMonthLimit.create!(workspace: @workspace, month: october, ai_plan: ai_plans(:scale), plan_name: "Scale", limit_usd: 1200)
    run!(price: 1446.15, ran_at: Time.zone.local(2026, 10, 20))

    get workshop_consumption_path(month: "2026-10")
    assert_includes response.body, "Over the limit by $246.15"
    assert_includes response.body, "Nothing was blocked"
    assert_includes response.body, "121% of the limit"
  end

  test "no plan says so and still shows prices" do
    run!(price: 318.72)
    get workshop_consumption_path
    assert_includes response.body, "NO PLAN"
    assert_includes response.body, "no limit set"
    assert_includes response.body, "$318.72"
  end

  test "unknown runs are counted, not priced as $0" do
    run!(price: 2)
    run!(price: nil)
    run!(price: nil)
    get workshop_consumption_path
    assert_includes response.body, "2 runs"
    assert_includes response.body, "came back with no cost"
    assert_select "[data-run-price]", text: "unknown", count: 2
  end

  test "run list marks a deleted item, a stopped run, own key and the automation" do
    run!(price: 0.37, status: "stopped", item_type: "PrReview", item_id: 0)
    run!(price: 1.92, area: "designs", own_key: true, automation: nil, started_by: users(:one), item_label: "Thread · Nimbus")

    get workshop_consumption_path
    rows = css_select("[data-run-row]").map { |row| row.text.squish }
    assert_equal 2, rows.size
    assert rows.any? { |row| row.include?("DELETED") && row.include?("STOPPED") && row.include?("AUTOMATION") && row.include?("PR review") }
    assert rows.any? { |row| row.include?("OWN KEY") && row.include?(users(:one).name) }
  end

  test "all time lists each month against its own limit" do
    october = Date.new(2026, 10, 1)
    AiMonthLimit.create!(workspace: @workspace, month: october, plan_name: "Scale", limit_usd: 1200)
    run!(price: 1446.15, ran_at: Time.zone.local(2026, 10, 20))
    run!(price: 100)

    get workshop_consumption_path(view: "all")
    assert_includes response.body, "$1,546.15"
    assert_includes response.body, "over by $246.15"
    assert_select "[data-run-row]", count: 0
  end

  test "cost and margin never appear" do
    run!(price: 13)
    get workshop_consumption_path
    refute_includes response.body.downcase, "margin"
    refute_includes response.body, "$10.00"
  end

  test "the month picker offers each month with runs" do
    run!(price: 1, ran_at: Time.zone.local(2026, 10, 20))
    get workshop_consumption_path
    assert_select "select[name=month] option", text: /October 2026/
    assert_select "select[name=month] option", text: /\(this month\)/
  end

  test "show 50 more loads the next page" do
    51.times { |i| run!(price: 1, ran_at: i.minutes.ago) }
    get workshop_consumption_path
    assert_select "[data-run-row]", count: 50
    assert_select "a", text: "Show 50 more"

    get workshop_consumption_path(offset: 50), headers: { "Turbo-Frame" => "consumption_runs_50" }
    assert_select "turbo-frame#consumption_runs_50 [data-run-row]", count: 1
  end

  # Review Focus: an area or project whose runs all came back without a cost
  # reads unknown — never $0.00.
  test "an area whose runs all reported no cost reads unknown, not $0.00" do
    run!(price: 5)
    run!(price: nil, area: "ticket_chat")
    get workshop_consumption_path
    row = css_select("[data-consumption-row]").map { |r| r.text.squish }.find { |t| t.start_with?("Chat with AI on a ticket") }
    assert_equal "Chat with AI on a ticket 1 unknown", row
  end


  # Final review I1: a free plan is a natural thing to make; anything spent is over it.
  test "a $0 plan shows what was spent as over the limit" do
    plan = AiPlan.create!(name: "Trial", monthly_price_usd: 0, margin_percent: 30)
    @workspace.update!(ai_plan: plan)
    run!(price: 5)
    get workshop_consumption_path
    assert_response :success
    assert_includes response.body, "Over the limit by $5.00"
    get workshop_consumption_path(view: "all")
    assert_response :success
  end

  # Final review I3: a total with no priced run reads unknown, never $0.00.
  test "a month whose runs all reported no cost totals unknown" do
    run!(price: nil)
    get workshop_consumption_path
    css_select("[data-consumption-total]").each { |row| assert_includes row.text, "unknown" }
  end

end
