require "test_helper"
require "webmock/minitest"

class JiraClientWriteTest < ActiveSupport::TestCase
  def client
    JiraClient.new(domain: "ex.atlassian.net", email: "e@x.com", api_token: "tok")
  end

  test "create_issue posts and returns key + url" do
    stub_request(:post, "https://ex.atlassian.net/rest/api/3/issue")
      .to_return(status: 201, body: { key: "PROJ-99" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    res = client.create_issue(project_key: "PROJ", summary: "Hi", description_text: "Body", issue_type: "Task")
    assert res[:ok]
    assert_equal "PROJ-99", res[:key]
    assert_equal "https://ex.atlassian.net/browse/PROJ-99", res[:url]
  end

  test "create_issue surfaces an error on failure" do
    stub_request(:post, "https://ex.atlassian.net/rest/api/3/issue")
      .to_return(status: 400, body: { errorMessages: ["nope"] }.to_json)
    res = client.create_issue(project_key: "PROJ", summary: "Hi", description_text: "Body")
    assert_not res[:ok]
    assert res[:error].present?
  end

  test "update_issue_description PUTs and returns ok" do
    stub_request(:put, "https://ex.atlassian.net/rest/api/3/issue/PROJ-5")
      .to_return(status: 204, body: "")
    res = client.update_issue_description(issue_key: "PROJ-5", description_text: "New")
    assert res[:ok]
  end

  test "add_ai_action PUTs the custom field value" do
    stub_request(:put, "https://ex.atlassian.net/rest/api/3/issue/PROJ-5")
      .with(body: hash_including("fields" => { "customfield_10050" => [{ "value" => "Briefed" }] }))
      .to_return(status: 204, body: "")
    res = client.add_ai_action(issue_key: "PROJ-5", field_id: "customfield_10050", value: "Briefed")
    assert res[:ok]
  end

  test "fetch_field_id matches by name case-insensitively" do
    stub_request(:get, "https://ex.atlassian.net/rest/api/3/field")
      .to_return(status: 200,
                 body: [{ id: "customfield_10050", name: "AI actions" }].to_json,
                 headers: { "Content-Type" => "application/json" })
    assert_equal "customfield_10050", client.fetch_field_id("AI actions")
    assert_equal "customfield_10050", client.fetch_field_id("ai ACTIONS")
    assert_nil client.fetch_field_id("Nope")
  end
end
