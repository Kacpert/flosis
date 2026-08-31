require "test_helper"
require "webmock/minitest"

class JiraControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @project = projects(:jira_project)

    ENV["JIRA_DOMAIN"] = "test.atlassian.net"
    ENV["JIRA_EMAIL"] = "test@example.com"
    ENV["JIRA_API_TOKEN"] = "test-token"
  end

  test "projects returns Jira project list as JSON" do
    stub_request(:get, "https://test.atlassian.net/rest/api/3/project/search")
      .with(query: hash_including("startAt" => "0"))
      .to_return(
        status: 200,
        body: { values: [{ key: "ELV", name: "Elvium", id: "10001" }], isLast: true }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    get jira_projects_path, as: :json

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal 1, data.length
    assert_equal "ELV", data.first["key"]
  end

  test "projects returns empty array on Jira failure" do
    stub_request(:get, "https://test.atlassian.net/rest/api/3/project/search")
      .with(query: hash_including("startAt" => "0"))
      .to_return(status: 500)

    get jira_projects_path, as: :json

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "tasks returns sorted task list for a project" do
    get jira_tasks_project_path(@project), as: :json

    assert_response :success
    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.any? { |t| t["external_reference"] == "ELV-1" }
  end

  test "tasks only returns jira-synced tasks" do
    get jira_tasks_project_path(@project), as: :json

    data = JSON.parse(response.body)
    assert_not data.any? { |t| t["name"] == "Daily standup" }
  end

  # Regression: the timer bar's task picker fetches this endpoint for EVERY
  # Time & HR user, but it used to sit behind require_product!(:workshop). Most
  # employees have workshop_access = false, so the picker silently showed
  # nothing and they could not log time against a Jira ticket at all.
  test "an employee without workshop access can still list a project's Jira tasks" do
    membership = users(:two).membership_for(workspaces(:one))
    membership.update!(workshop_access: false)
    assert_not users(:two).can_access_product?(workspaces(:one), :workshop)
    ProjectMembership.find_or_create_by!(project: @project, user: users(:two))
    sign_in_as(users(:two))

    get jira_tasks_project_path(@project), as: :json

    assert_response :success
    assert data_keys(response).any? { |k| k == "ELV-1" }
  end

  test "a workspace_client with Time & HR can list a project's Jira tasks" do
    sign_in_as(users(:workspace_client_user))

    get jira_tasks_project_path(@project), as: :json

    assert_response :success
  end

  # Dropping the Workshop gate must not widen what a user can see: an employee
  # still only reaches Jira projects they are a member of (visible_jira_projects).
  test "an employee who is not a member of the project is refused with JSON, not a redirect" do
    users(:two).membership_for(workspaces(:one)).update!(workshop_access: false)
    ProjectMembership.where(project: @project, user: users(:two)).destroy_all
    sign_in_as(users(:two))

    get jira_tasks_project_path(@project), as: :json

    assert_response :not_found
    assert_equal "You don't have access to that.", JSON.parse(response.body)["error"]
  end

  test "sync triggers sync and redirects" do
    stub_jira_sync_requests

    post jira_sync_project_path(@project)

    assert_redirected_to project_path(@project)
  end

  test "sync requires admin" do
    users(:two).membership_for(workspaces(:one)).update!(workshop_access: true)
    sign_in_as(users(:two))

    post jira_sync_project_path(@project)

    assert_redirected_to root_path
  end

  test "projects requires admin" do
    users(:two).membership_for(workspaces(:one)).update!(workshop_access: true)
    sign_in_as(users(:two))

    get jira_projects_path, as: :json

    assert_response :forbidden
  end

  private

  def data_keys(response)
    JSON.parse(response.body).map { |t| t["external_reference"] }
  end

  def stub_jira_sync_requests
    stub_request(:get, /rest\/agile\/1.0\/board\?/)
      .to_return(status: 200, body: { values: [], isLast: true }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://test.atlassian.net/rest/api/3/status")
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://test.atlassian.net/rest/api/3/field")
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://test.atlassian.net/rest/api/3/search/jql")
      .to_return(status: 200, body: { issues: [] }.to_json, headers: { "Content-Type" => "application/json" })
  end
end
