require "test_helper"

class Reports::ProjectReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    @month = "2026-06"
    @from = Date.new(2026, 6, 1).beginning_of_month
    @project.time_entries.create!(workspace: @project.workspace, user: users(:one),
      started_at: @from + 9.hours, stopped_at: @from + 12.hours) # 3h
    @project.tasks.create!(name: "CA", external_type: "jira", external_reference: "CA-9",
      jira_status_name: "Customer Acceptance", jira_updated_at: @from + 1.day)
    @project.tasks.create!(name: "Bugz", external_type: "jira", external_reference: "B-9",
      issue_type: "Bug", jira_updated_at: @from + 1.day)
  end

  test "admin sees the report with the three figures" do
    sign_in_as(users(:one))
    get reports_project_report_path(project_id: @project.id, month: @month)
    assert_response :success
    assert_match "3h 0m", response.body            # hours (format_duration_hm)
    assert_match "Customer Acceptance", response.body
    assert_match users(:one).name, response.body   # per-user row
  end

  test "employee is blocked" do
    sign_in_as(users(:two))
    get reports_project_report_path(project_id: @project.id, month: @month)
    assert_redirected_to root_path
  end

  test "defaults to current month and first project when params omitted" do
    sign_in_as(users(:one))
    get reports_project_report_path
    assert_response :success
  end

  test "a project from another workspace is not accessible" do
    other_ws = workspaces(:two)
    other_project = other_ws.projects.create!(name: "Foreign", color: "#000000")
    sign_in_as(users(:one)) # member of workspace one
    get reports_project_report_path(project_id: other_project.id, month: @month)
    # falls back to a project in the current workspace rather than leaking another workspace's
    assert_response :success
    assert_not_includes response.body, "Foreign"
  end
end
