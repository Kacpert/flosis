require "test_helper"

class AiMonthLimitTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @plan = ai_plans(:scale)
    @workspace.update!(ai_plan: @plan, ai_plan_assigned_at: Time.current)
  end

  test "ensure_current! freezes the plan that stands now and never overwrites" do
    AiMonthLimit.ensure_current!(@workspace)
    @plan.update_columns(monthly_price_usd: 1500)
    AiMonthLimit.ensure_current!(@workspace.reload)

    row = AiMonthLimit.find_by!(workspace: @workspace, month: Date.current.beginning_of_month)
    assert_equal BigDecimal("1200"), row.limit_usd
    assert_equal "Scale", row.plan_name
  end

  test "refresh_current! follows a plan change this month only" do
    last_month = Date.current.beginning_of_month.prev_month
    AiMonthLimit.create!(workspace: @workspace, month: last_month, ai_plan: @plan, plan_name: "Scale", limit_usd: 1200)
    @plan.update_columns(monthly_price_usd: 1500)
    AiMonthLimit.refresh_current!(@workspace.reload)

    assert_equal BigDecimal("1200"), AiMonthLimit.find_by!(workspace: @workspace, month: last_month).limit_usd
    assert_equal BigDecimal("1500"), AiMonthLimit.find_by!(workspace: @workspace, month: Date.current.beginning_of_month).limit_usd
  end

  test "for a current month without a row builds one from the live plan" do
    row = AiMonthLimit.for(@workspace, Date.current)
    assert row.new_record?
    assert_equal BigDecimal("1200"), row.limit_usd
  end

  test "for a past month without a row is nil" do
    assert_nil AiMonthLimit.for(@workspace, Date.current.prev_month)
  end

  test "an organization with no plan freezes a month with no limit" do
    @workspace.update!(ai_plan: nil)
    AiMonthLimit.ensure_current!(@workspace)
    row = AiMonthLimit.find_by!(workspace: @workspace, month: Date.current.beginning_of_month)
    assert_nil row.limit_usd
    assert_nil row.plan_name
  end
end
