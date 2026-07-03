require "test_helper"
class TwoProductUxSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @ws = workspaces(:one)
    @ws.update!(workshop_enabled: true)
  end

  test "owner: time_hr product shows time nav, switcher, no workshop tab" do
    sign_in_as(users(:one))
    get time_entries_path
    assert_response :success
    assert_select "a[href=?]", time_entries_path
    assert_select "a[href=?]", projects_path        # Manage
    assert_select "a[href=?]", reports_summary_path  # Reports
    assert_select "a[href=?]", workshop_path, count: 0
    assert_select "a[href=?]", jira_tasks_path, count: 0
    # switcher present (two products accessible)
    assert_match "Time &amp; HR", response.body
    assert_match "Workshop", response.body
  end

  test "owner: workshop product shows jira + workshop, no time nav" do
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    assert_redirected_to workshop_pipeline_path
    get workshop_pipeline_path
    assert_response :success
    assert_select "a[href=?]", jira_tasks_path
    assert_select "a[href=?]", workshop_pipeline_path
    assert_select "a[href=?]", time_entries_path, count: 0
    assert_select "a[href=?]", projects_path, count: 0
  end

  test "workshop top bar has the project switcher, NOT the timer/Start" do
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    get workshop_pipeline_path
    assert_response :success
    # project switcher present (posts to the workshop project switch route) —
    # now the Clar top-bar dropdown (Task 1.2), not the old M3 "Working in" select.
    assert_select "form[action=?]", switch_workshop_project_path
    assert_match "SWITCH PROJECT", response.body
    # the time-tracking timer must NOT appear in Workshop
    assert_select "form[action=?]", update_running_timer_path, count: 0
    assert_select "[data-controller~=timer]", count: 0
    # the redundant landing Project picker + per-card Start is gone
    assert_select "form[action=?]", start_workshop_path, count: 0
  end

  test "switching the workshop project sets the context" do
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    p = projects(:jira_project)
    post switch_workshop_project_path, params: { project_id: p.id }
    assert_response :redirect
    follow_redirect! rescue nil
    # the new context is reflected on the landing (now the Create Tasks pipeline)
    get workshop_pipeline_path
    assert_match p.name, response.body
  end

  test "workshop landing offers New idea / Existing Jira task entry points" do
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    p = projects(:jira_project)
    post switch_workshop_project_path, params: { project_id: p.id }
    get workshop_pipeline_path
    assert_response :success
    # Task 2.3 redesign: the two entry points are now clar-modal-opening cards
    # on the Create Tasks pipeline landing (modals themselves land in Phase 3).
    assert_select "h1", "Create Tasks"
    assert_select "button[data-action=?]", "clar-modal#open", count: 2
    assert_match "New idea", response.body
    assert_match "Existing Jira task", response.body
    # the project context still lives in the top-bar switcher
    assert_select "form[action=?]", switch_workshop_project_path, minimum: 1
  end

  test "employee (time_hr only): no switcher dropdown, no workshop access" do
    sign_in_as(users(:two))
    get time_entries_path
    assert_response :success
    assert_select "a[href=?]", time_entries_path
    # only one product → static label, switch button absent
    assert_select "form[action=?]", switch_product_path, count: 0
    # direct workshop hit bounced
    get jira_tasks_path
    assert_redirected_to time_entries_path
  end

  test "switching to an inaccessible product is rejected" do
    sign_in_as(users(:two)) # no workshop
    post switch_product_path, params: { product: "workshop" }
    assert_redirected_to time_entries_path
    get jira_tasks_path
    assert_redirected_to time_entries_path # still blocked
  end
end
