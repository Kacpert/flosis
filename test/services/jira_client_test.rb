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

  # Every call made for a project goes to that project's Jira: a new
  # organization's own site, or the server's when the project sets none.
  test "a project's client talks to the project's own Jira" do
    project = projects(:jira_project)
    project.update!(jira_site: "flosis-test.atlassian.net", jira_email: "kacper@example.test", jira_api_token: "project-token")
    stub = stub_request(:get, %r{\Ahttps://flosis-test\.atlassian\.net/rest/api/3/project/search}).with(basic_auth: [ "kacper@example.test", "project-token" ])
                                                                                            .to_return(status: 200, body: { values: [] }.to_json)
    JiraClient.for(project).fetch_projects
    assert_requested stub
  end

  # The Estimation target card offers the number fields an estimate can be
  # written to on this project: the site's own, and this team-managed
  # project's, never another project's or a system field.
  test "fetch_number_fields lists the custom number fields this project can carry" do
    stub_request(:get, "#{@base_url}/field").to_return(status: 200, body: [
      { id: "customfield_10016", name: "Story point estimate", custom: true, schema: { type: "number" } },
      { id: "customfield_10200", name: "AI estimation", custom: true, schema: { type: "number" }, scope: { type: "PROJECT", project: { id: "10000" } } },
      { id: "customfield_10300", name: "Their estimate", custom: true, schema: { type: "number" }, scope: { type: "PROJECT", project: { id: "10099" } } },
      { id: "customfield_10020", name: "Sprint", custom: true, schema: { type: "array" } },
      { id: "aggregatetimespent", name: "Σ Time Spent", custom: false, schema: { type: "number" } }
    ].to_json)
    stub_request(:get, "#{@base_url}/project/SCRUM").to_return(status: 200, body: { id: "10000", key: "SCRUM" }.to_json)

    assert_equal [ "AI estimation", "Story point estimate" ], @client.fetch_number_fields("SCRUM")
  end

  test "fetch_number_fields is nil when Jira can't be read" do
    stub_request(:get, "#{@base_url}/field").to_return(status: 401, body: "")

    assert_nil @client.fetch_number_fields("SCRUM")
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

  test "upsert_remote_link posts the link under its globalId" do
    stub = stub_request(:post, "#{@base_url}/issue/REC-1/remotelink")
           .with(body: { globalId: "g:1", object: { url: "https://x.example/a", title: "Design · A" } }.to_json)
           .to_return(status: 201, body: "{}")
    assert_equal({ ok: true, error: nil }, @client.upsert_remote_link(issue_key: "REC-1", global_id: "g:1",
                                                                      url: "https://x.example/a", title: "Design · A"))
    assert_requested stub
  end

  test "remote_links lists the globalIds of the issue's links" do
    stub_request(:get, "#{@base_url}/issue/REC-1/remotelink")
      .to_return(status: 200, body: [ { id: 1, globalId: "g:1" }, { id: 2 } ].to_json)
    assert_equal({ ok: true, global_ids: [ "g:1" ], error: nil }, @client.remote_links("REC-1"))
  end

  test "remote_links says so when Jira does not answer" do
    stub_request(:get, "#{@base_url}/issue/REC-1/remotelink").to_return(status: 404, body: "{}")
    result = @client.remote_links("REC-1")
    assert_not result[:ok]
    assert_equal [], result[:global_ids]
    assert result[:error].present?
  end

  test "delete_remote_link deletes by escaped globalId and sends no body" do
    stub = stub_request(:delete, "#{@base_url}/issue/REC-1/remotelink?globalId=#{CGI.escape("g:1 a/b")}")
           .with { |request| request.body.blank? }
           .to_return(status: 204)
    assert_equal({ ok: true, error: nil }, @client.delete_remote_link(issue_key: "REC-1", global_id: "g:1 a/b"))
    assert_requested stub
  end
end
