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

    assert_redirected_to root_path
  end

  private

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
