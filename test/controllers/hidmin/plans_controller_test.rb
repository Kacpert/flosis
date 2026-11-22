require "test_helper"

# SCRUM-70: Flosis staff make plans — a monthly price (the organization's
# limit), a margin and the models it includes — and assign them.
class Hidmin::PlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
    @opus = AiModel.create!(model_id: "claude-opus-5-5", name: "Claude Opus 5.5", input_usd_per_mtok: 15, output_usd_per_mtok: 75,
                            cache_write_usd_per_mtok: 18.75, cache_read_usd_per_mtok: 1.5)
    @haiku = AiModel.create!(model_id: "claude-haiku-5-5", name: "Claude Haiku 5.5", input_usd_per_mtok: 1, output_usd_per_mtok: 5,
                             price_source: "hand", hand_set_at: Time.current)
  end

  test "staff create a plan with models and assign it" do
    post hidmin_plans_path, params: { ai_plan: { name: "Growth", monthly_price_usd: "1200", margin_percent: "30",
                                                 ai_model_ids: [ @opus.id, @haiku.id ] },
                                      assign_workspace_id: workspaces(:two).id }
    plan = AiPlan.find_by!(name: "Growth")
    assert_redirected_to hidmin_plans_path
    assert_equal 2, plan.ai_models.count
    workspace = workspaces(:two).reload
    assert_equal plan, workspace.ai_plan
    assert workspace.ai_plan_assigned_at
    assert_equal BigDecimal("1200"), AiMonthLimit.find_by!(workspace: workspace, month: Date.current.beginning_of_month).limit_usd
  end

  test "the plans list shows price, margin, models and organizations" do
    plan = ai_plans(:scale)
    plan.ai_models << @opus
    workspaces(:one).update!(ai_plan: plan)

    get hidmin_plans_path
    row = css_select("[data-plan-row]").map { |r| r.text.squish }.find { |t| t.include?("Scale") }
    assert_includes row, "$1,200.00"
    assert_includes row, "30%"
    assert_includes row, "Claude Opus 5.5"
    assert_includes row, "Test Workspace"
  end

  test "a plan needs a name, a price and a margin" do
    post hidmin_plans_path, params: { ai_plan: { name: "", monthly_price_usd: "", margin_percent: "" } }
    assert_response :unprocessable_entity
    assert_equal 1, AiPlan.count
  end

  test "the new plan form lists each model's prices and marks typed ones" do
    get new_hidmin_plan_path
    assert_response :success
    assert_includes response.body, "Claude Opus 5.5"
    assert_includes response.body, "$75.00"
    assert_includes response.body, "BY HAND"
    # The current family is always offered (AiModel.seed!), Sonnet included.
    assert_includes response.body, "Claude Sonnet 5.5"
    assert_select "input[type=checkbox][name='ai_plan[ai_model_ids][]']", count: AiModel.count
  end

  test "editing a plan leaves last month's limit" do
    plan = ai_plans(:scale)
    workspace = workspaces(:one)
    workspace.update!(ai_plan: plan)
    last_month = Date.current.beginning_of_month.prev_month
    AiMonthLimit.create!(workspace: workspace, month: last_month, ai_plan: plan, plan_name: "Scale", limit_usd: 1200)

    patch hidmin_plan_path(plan), params: { ai_plan: { monthly_price_usd: "1500" } }
    assert_redirected_to hidmin_plans_path
    assert_equal BigDecimal("1200"), AiMonthLimit.find_by!(workspace: workspace, month: last_month).limit_usd
    assert_equal BigDecimal("1500"), AiMonthLimit.find_by!(workspace: workspace, month: Date.current.beginning_of_month).limit_usd
  end

  test "editing a margin leaves recorded runs as they were" do
    plan = ai_plans(:scale)
    run = AiRun.create!(workspace: workspaces(:one), area: "agents", automation: "X", status: "succeeded", ran_at: 1.day.ago,
                        cost_usd: 10, margin_percent: 30, price_usd: 13)
    patch hidmin_plan_path(plan), params: { ai_plan: { margin_percent: "50" } }
    assert_equal BigDecimal("13"), run.reload.price_usd
    assert_equal BigDecimal("50"), plan.reload.margin_percent
  end
end
