require "test_helper"
require "webmock/minitest"

class JiraClientTest < ActiveSupport::TestCase
  setup do
    @client = JiraClient.new(
      domain: "test.atlassian.net",
      email: "test@example.com",
      api_token: "test-token"
    )
    @base_url = "https://test.atlassian.net/rest/api/3"
  end

  test "fetch_projects returns list of projects" do
    stub_request(:get, "#{@base_url}/project/search")
      .with(
        headers: { "Authorization" => "Basic #{Base64.strict_encode64('test@example.com:test-token')}" },
        query: hash_including({})
      )
      .to_return(
        status: 200,
        body: {
          values: [
            { key: "ELV", name: "Elvium", id: "10001" },
            { key: "GOLD", name: "Gold App", id: "10002" }
          ],
          isLast: true
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    projects = @client.fetch_projects

    assert_equal 2, projects.length
    assert_equal "ELV", projects.first[:key]
    assert_equal "Elvium", projects.first[:name]
  end

  test "fetch_projects returns empty array on failure" do
    stub_request(:get, "#{@base_url}/project/search")
      .with(query: hash_including({}))
      .to_return(status: 401, body: "Unauthorized")

    projects = @client.fetch_projects

    assert_equal [], projects
  end

  test "fetch_issues returns issues with status category" do
    stub_request(:post, "#{@base_url}/search/jql")
      .to_return(
        status: 200,
        body: {
          issues: [
            {
              key: "ELV-42",
              fields: {
                summary: "Fix login page",
                status: {
                  name: "In Progress",
                  statusCategory: { key: "indeterminate", name: "In Progress" }
                },
                assignee: { emailAddress: "kacper@example.com" }
              }
            }
          ],
          total: 1,
          startAt: 0,
          maxResults: 100
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    issues = @client.fetch_issues("ELV")

    assert_equal 1, issues.length
    issue = issues.first
    assert_equal "ELV-42", issue[:key]
    assert_equal "Fix login page", issue[:summary]
    assert_equal "indeterminate", issue[:status_category]
    assert_equal "In Progress", issue[:status_name]
    assert_equal "kacper@example.com", issue[:assignee_email]
    assert_equal "https://test.atlassian.net/browse/ELV-42", issue[:url]
  end

  test "fetch_issues handles pagination" do
    stub_request(:post, "#{@base_url}/search/jql")
      .to_return(
        { status: 200, body: {
          issues: Array.new(100) { |i| { key: "ELV-#{i}", fields: { summary: "Issue #{i}", status: { name: "To Do", statusCategory: { key: "new" } }, assignee: nil } } },
          nextPageToken: "page2"
        }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: {
          issues: Array.new(50) { |i| { key: "ELV-#{100 + i}", fields: { summary: "Issue #{100 + i}", status: { name: "To Do", statusCategory: { key: "new" } }, assignee: nil } } },
          nextPageToken: nil
        }.to_json, headers: { "Content-Type" => "application/json" } }
      )

    issues = @client.fetch_issues("ELV")

    assert_equal 150, issues.length
  end

  test "fetch_issues returns empty array on timeout" do
    stub_request(:post, "#{@base_url}/search/jql")
      .to_timeout

    issues = @client.fetch_issues("ELV")

    assert_equal [], issues
  end

  test "fetch_issues validates project key format" do
    issues = @client.fetch_issues("'; DROP TABLE --")

    assert_equal [], issues
  end
end
