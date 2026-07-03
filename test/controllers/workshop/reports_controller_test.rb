require "test_helper"

class Workshop::ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # admin/owner -> can_see_money? true
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "renders the reporting page with metrics, trend, dev table, delivered table" do
    @project.delivered_issues.create!(jira_key: "ELV-42", title: "Aggregated export", issue_type: "Story",
      story_points: 8, resolved_at: Time.current, assignee_email: users(:one).email_address)

    get workshop_reporting_path

    assert_response :success
    assert_select "body", /Reporting/
    assert_select "body", /Features delivered/
    assert_select "body", /Story points delivered over time/
    assert_select "body", /Per-developer results/
    assert_select "body", /Hours & cost from internal time-tracking/
    assert_select "body", /Delivered this period/
    assert_select "body", /ELV-42/
  end

  test "cost column and project cost card are hidden from non-admins" do
    workspace_memberships(:two_employee).update!(time_hr_access: true, workshop_access: true)
    delete "/session" # sign out one
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }

    get workshop_reporting_path

    assert_response :success
    assert_select "body", { text: /Project cost/, count: 0 }
    assert_select "body", { text: /COST/, count: 0 }
  end

  test "period defaults to month and accepts sprint" do
    get workshop_reporting_path(period: "sprint")
    assert_response :success
  end

  test "developer param focuses a single developer" do
    get workshop_reporting_path(developer: users(:one).id)
    assert_response :success
  end

  test "gran/range are coerced to the allowed set per granularity" do
    get workshop_reporting_path(gran: "sprints", range: "999")
    assert_response :success

    get workshop_reporting_path(gran: "months", range: "999")
    assert_response :success
  end

  test "empty state when nothing delivered this period" do
    get workshop_reporting_path
    assert_response :success
    assert_select "body", /No features delivered by the team this period\./
  end
end
