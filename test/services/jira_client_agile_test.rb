require "test_helper"
require "webmock/minitest"

class JiraClientAgileTest < ActiveSupport::TestCase
  setup do
    @client = JiraClient.new(
      domain: "test.atlassian.net",
      email: "test@example.com",
      api_token: "test-token"
    )
    @agile_url = "https://test.atlassian.net/rest/agile/1.0"
  end

  test "fetch_boards returns boards for a project" do
    stub_request(:get, "#{@agile_url}/board")
      .with(query: hash_including("projectKeyOrId" => "ELV"))
      .to_return(
        status: 200,
        body: {
          values: [
            { id: 101, name: "Design", type: "scrum" },
            { id: 102, name: "DEV board", type: "scrum" }
          ],
          isLast: true
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    boards = @client.fetch_boards("ELV")
    assert_equal 2, boards.length
    assert_equal 101, boards.first[:id]
    assert_equal "Design", boards.first[:name]
    assert_equal "scrum", boards.first[:type]
  end

  test "fetch_boards returns empty array on failure" do
    stub_request(:get, "#{@agile_url}/board")
      .with(query: hash_including("projectKeyOrId" => "ELV"))
      .to_return(status: 500)

    assert_equal [], @client.fetch_boards("ELV")
  end

  test "fetch_board_configuration returns columns with statuses" do
    stub_request(:get, "#{@agile_url}/board/101/configuration")
      .to_return(
        status: 200,
        body: {
          columnConfig: {
            columns: [
              { name: "TO DO (DESIGN)", statuses: [{ id: "10001", self: "https://..." }] },
              { name: "IN PROGRESS (DESIGN)", statuses: [{ id: "10002", self: "https://..." }] },
              { name: "DONE (DESIGN)", statuses: [{ id: "10003", self: "https://..." }] }
            ]
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    columns = @client.fetch_board_configuration(101)
    assert_equal 3, columns.length
    assert_equal "TO DO (DESIGN)", columns.first[:name]
    assert_equal [{ id: "10001" }], columns.first[:statuses]
  end

  test "fetch_board_configuration returns empty on failure" do
    stub_request(:get, "#{@agile_url}/board/101/configuration")
      .to_return(status: 404)

    assert_equal [], @client.fetch_board_configuration(101)
  end

  test "fetch_sprints returns sprints for a board" do
    stub_request(:get, "#{@agile_url}/board/101/sprint")
      .with(query: hash_including({}))
      .to_return(
        status: 200,
        body: {
          values: [
            { id: 569, name: "Design Sprint", state: "active", startDate: "2026-03-01T00:00:00.000Z", endDate: "2026-03-15T00:00:00.000Z" },
            { id: 33, name: "Old Sprint", state: "closed", startDate: "2026-02-01T00:00:00.000Z", endDate: "2026-02-28T00:00:00.000Z" }
          ],
          isLast: true
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    sprints = @client.fetch_sprints(101)
    assert_equal 2, sprints.length
    assert_equal 569, sprints.first[:id]
    assert_equal "Design Sprint", sprints.first[:name]
    assert_equal "active", sprints.first[:state]
  end

  test "fetch_sprints returns empty on failure" do
    stub_request(:get, "#{@agile_url}/board/101/sprint")
      .with(query: hash_including({}))
      .to_return(status: 500)

    assert_equal [], @client.fetch_sprints(101)
  end

  test "adf_to_text extracts text from ADF document" do
    adf = {
      "type" => "doc",
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello world" }] },
        { "type" => "heading", "attrs" => { "level" => 2 }, "content" => [{ "type" => "text", "text" => "Section" }] },
        { "type" => "bulletList", "content" => [
          { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Item 1" }] }] },
          { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Item 2" }] }] }
        ] }
      ]
    }

    text = @client.send(:adf_to_text, adf)
    assert_includes text, "Hello world"
    assert_includes text, "Section"
    assert_includes text, "Item 1"
    assert_includes text, "Item 2"
  end

  test "adf_to_text handles nil" do
    assert_nil @client.send(:adf_to_text, nil)
  end

  test "fetch_issues returns extended fields" do
    stub_request(:post, "https://test.atlassian.net/rest/api/3/search/jql")
      .to_return(
        status: 200,
        body: {
          issues: [
            {
              key: "ELV-42",
              fields: {
                summary: "Fix login page",
                status: { name: "In Progress", statusCategory: { key: "indeterminate" } },
                assignee: { emailAddress: "kacper@example.com" },
                description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Fix the bug" }] }] },
                priority: { name: "High" },
                issuetype: { name: "Bug" },
                labels: ["urgent", "frontend"],
                reporter: { emailAddress: "reporter@example.com" },
                sprint: { id: 569, name: "Design Sprint" },
                timeoriginalestimate: 7200
              }
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    issues = @client.fetch_issues("ELV")
    issue = issues.first
    assert_equal "Fix the bug", issue[:description]
    assert_equal "High", issue[:priority]
    assert_equal "Bug", issue[:issue_type]
    assert_equal ["urgent", "frontend"], issue[:labels]
    assert_equal "reporter@example.com", issue[:reporter_email]
    assert_equal 569, issue[:sprint_id]
    assert_equal "Design Sprint", issue[:sprint_name]
    assert_equal 7200, issue[:time_estimate_seconds]
  end
end
