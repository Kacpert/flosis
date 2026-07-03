require "test_helper"
require "webmock/minitest"

class JiraTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @project = projects(:jira_project)
    @board = jira_boards(:design_board)

    ENV["JIRA_DOMAIN"] = "test.atlassian.net"
    ENV["JIRA_EMAIL"] = "test@example.com"
    ENV["JIRA_API_TOKEN"] = "test-token"
  end

  test "index shows jira tasks page" do
    get jira_tasks_path
    assert_response :success
    assert_select "h1", /Jira Tasks/
  end

  test "index loads project when project_id param given" do
    get jira_tasks_path(project_id: @project.id)
    assert_response :success
  end

  test "index is shown to an employee granted Workshop access" do
    users(:two).membership_for(workspaces(:one)).update!(workshop_access: true)
    sign_in_as(users(:two))
    get jira_tasks_path
    assert_response :success
  end

  test "index is blocked for an employee without Workshop access" do
    sign_in_as(users(:two))
    get jira_tasks_path
    assert_redirected_to time_entries_path
  end

  test "board_data returns kanban view" do
    get board_data_jira_tasks_path(project_id: @project.id, board_id: @board.id, view: "kanban")
    assert_response :success
  end

  test "board_data returns list view" do
    get board_data_jira_tasks_path(project_id: @project.id, board_id: @board.id, view: "list")
    assert_response :success
  end

  test "board_data filters by sprint" do
    sprint = jira_sprints(:design_sprint)
    get board_data_jira_tasks_path(project_id: @project.id, board_id: @board.id, sprint_id: sprint.id, view: "kanban")
    assert_response :success
  end

  test "show returns task detail" do
    task = tasks(:jira_task)
    get jira_task_path(task)
    assert_response :success
  end

  test "refresh triggers sync and redirects" do
    stub_request(:get, /rest\/agile\/1.0\/board\?/)
      .to_return(status: 200, body: { values: [], isLast: true }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://test.atlassian.net/rest/api/3/status")
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://test.atlassian.net/rest/api/3/field")
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, /rest\/api\/3\/search\/jql/)
      .to_return(status: 200, body: { issues: [] }.to_json, headers: { "Content-Type" => "application/json" })

    post refresh_jira_tasks_path(project_id: @project.id)
    assert_response :redirect
  end
end

