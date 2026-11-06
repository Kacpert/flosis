require "test_helper"
require "webmock/minitest"

# What JiraSyncService#sync_deleted_issues asks Jira: every key in the project,
# whether the login may still browse it, and — per missing key — whether the
# issue is really gone. Anything Jira did not clearly answer counts as "don't know".
class JiraClientDeletedIssuesTest < ActiveSupport::TestCase
  setup do
    @client = JiraClient.new(domain: "test.atlassian.net", email: "test@example.com", api_token: "test-token")
    @base_url = "https://test.atlassian.net/rest/api/3"
  end

  test "fetch_issue_keys returns every key in the project, closed issues included, across pages" do
    stub_request(:post, "#{@base_url}/search/jql")
      .with { |r| body = JSON.parse(r.body); body["jql"] == "project = ELV" && body["fields"] == [ "key" ] && body["nextPageToken"].nil? }
      .to_return(status: 200, body: { issues: [ { key: "ELV-1" }, { key: "ELV-2" } ], nextPageToken: "p2" }.to_json)
    stub_request(:post, "#{@base_url}/search/jql")
      .with { |r| JSON.parse(r.body)["nextPageToken"] == "p2" }
      .to_return(status: 200, body: { issues: [ { key: "ELV-9" } ], isLast: true }.to_json)

    assert_equal %w[ELV-1 ELV-2 ELV-9], @client.fetch_issue_keys("ELV")
  end

  test "fetch_issue_keys is nil, not empty, when a page fails" do
    stub_request(:post, "#{@base_url}/search/jql").to_return(status: 500, body: "")

    assert_nil @client.fetch_issue_keys("ELV")
  end

  test "fetch_issue_keys refuses a malformed project key" do
    assert_nil @client.fetch_issue_keys("elv; drop")
  end

  test "can_browse_project? is true only when Jira says so" do
    stub_request(:get, "#{@base_url}/mypermissions").with(query: { projectKey: "ELV", permissions: "BROWSE_PROJECTS" })
      .to_return(status: 200, body: { permissions: { BROWSE_PROJECTS: { havePermission: true } } }.to_json)

    assert @client.can_browse_project?("ELV")
  end

  test "can_browse_project? is false without the permission, for an unknown project and on errors" do
    stub_request(:get, "#{@base_url}/mypermissions").with(query: { projectKey: "ELV", permissions: "BROWSE_PROJECTS" })
      .to_return(status: 200, body: { permissions: { BROWSE_PROJECTS: { havePermission: false } } }.to_json)
    assert_not @client.can_browse_project?("ELV")

    stub_request(:get, "#{@base_url}/mypermissions").with(query: { projectKey: "NOPE", permissions: "BROWSE_PROJECTS" })
      .to_return(status: 404, body: { errorMessages: [ "Could not find project with provided key." ] }.to_json)
    assert_not @client.can_browse_project?("NOPE")

    stub_request(:get, "#{@base_url}/mypermissions").with(query: { projectKey: "DOWN", permissions: "BROWSE_PROJECTS" }).to_timeout
    assert_not @client.can_browse_project?("DOWN")
  end

  test "issue_gone? is true when Jira answers 404" do
    stub_request(:get, "#{@base_url}/issue/ELV-7").with(query: { fields: "project" }).to_return(status: 404, body: "")

    assert @client.issue_gone?("ELV-7", "ELV")
  end

  test "issue_gone? is true when the issue now lives in another project" do
    stub_request(:get, "#{@base_url}/issue/ELV-7").with(query: { fields: "project" })
      .to_return(status: 200, body: { key: "OPS-3", fields: { project: { key: "OPS" } } }.to_json)

    assert @client.issue_gone?("ELV-7", "ELV")
  end

  test "issue_gone? is false while the issue is still in the project" do
    stub_request(:get, "#{@base_url}/issue/ELV-7").with(query: { fields: "project" })
      .to_return(status: 200, body: { key: "ELV-7", fields: { project: { key: "ELV" } } }.to_json)

    assert_not @client.issue_gone?("ELV-7", "ELV")
  end

  test "issue_gone? is false when Jira does not clearly answer" do
    stub_request(:get, "#{@base_url}/issue/ELV-7").with(query: { fields: "project" }).to_return(status: 401, body: "")
    assert_not @client.issue_gone?("ELV-7", "ELV")

    stub_request(:get, "#{@base_url}/issue/ELV-8").with(query: { fields: "project" }).to_return(status: 503, body: "")
    assert_not @client.issue_gone?("ELV-8", "ELV")

    stub_request(:get, "#{@base_url}/issue/ELV-9").with(query: { fields: "project" }).to_timeout
    assert_not @client.issue_gone?("ELV-9", "ELV")
  end
end
