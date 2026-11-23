require "test_helper"

# SCRUM-71: what an organization's people see while its AI is paused, and
# the billing banners its admins see above the top bar.
class AiPausedScreensTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
  end

  def enter_workshop(user)
    sign_in_as(user)
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "paused: the admin's banner, the amber Claude card and the note on Agents & Automations" do
    travel_to Time.zone.local(2026, 11, 26, 9) do
      pause_ai!(@workspace)
      enter_workshop(users(:one))
      get workshop_process_path(tab: "alerts")
      assert_select "[data-billing-banner=paused]", text: /AI paused: this month’s limit is reached and the top-up balance is empty\. Top up in Billing/
      assert_select "[data-ai-paused-card]", text: /Claude Opus · paused/
      assert_select "[data-ai-paused-card]", text: /AI limit reached · back on 1 Dec or after a top-up/
      assert_select "[data-paused-note=admin]", text: /PR reviews, estimates and alert rules don’t run until an admin tops up/
    end
  end

  test "a member sees no banner, and is told to ask an admin" do
    travel_to Time.zone.local(2026, 11, 26, 9) do
      pause_ai!(@workspace)
      enter_workshop(users(:two))
      get workshop_bugs_path
      assert_select "[data-billing-banner]", count: 0
      assert_select "[data-paused-note=member]", text: /Ask an admin to top up\./
    end
  end

  test "past 80% of the limit the admin sees the amber banner" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(billing_plan(name: "Starter", price: 200)) }
    travel_to Time.zone.local(2026, 11, 18, 14) do
      AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "succeeded", cost_usd: 1, price_usd: 165, ran_at: Time.current, funding: "plan")
      enter_workshop(users(:one))
      get workshop_process_path
      assert_select "[data-billing-banner=near-limit]", text: /You’ve used 80% of this month’s AI limit \(\$160 of \$200\)\. See Consumption/
    end
  end

  test "a failing payment: the red banner with the allowance and the retry day" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(billing_plan(name: "Starter", price: 200)) }
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to Time.zone.local(2026, 12, 3, 9) do
      enter_workshop(users(:one))
      get workshop_process_path
      assert_select "[data-billing-banner=payment-failed]", text: /Payment failed, update your card\. AI keeps running up to \$30\.00 while we retry \(day 3 of 7\)\. Update card/
    end
  end

  test "no plan and no free AI: the admin is sent to choose a plan, a member to an admin" do
    @workspace.update!(free_ai: false)
    enter_workshop(users(:one))
    get workshop_process_path
    assert_select "[data-billing-banner=no-plan]", text: /AI paused: Test Workspace has no plan\. Choose a plan in Billing/
    assert_select "[data-ai-paused-card]", text: /No plan · back once one is chosen in Billing/
    assert_select "[data-paused-note=admin]", text: /AI paused: no plan\..*Choose a plan in Billing\./m
    sign_out
    enter_workshop(users(:two))
    get workshop_bugs_path
    assert_select "[data-billing-banner]", count: 0
    assert_select "[data-paused-note=member]", text: /Ask an admin to choose a plan\./
  end

  test "Flosis staff turn free AI on in hidmin" do
    users(:one).update!(flosis_staff: true)
    @workspace.update!(free_ai: false)
    sign_in_as(users(:one))
    patch hidmin_workspace_path(@workspace), params: { workspace: { free_ai: "1" } }
    assert @workspace.reload.free_ai
    assert_not Billing::Allowance.for(@workspace).paused?
  end
end
