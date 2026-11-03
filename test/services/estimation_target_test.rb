require "test_helper"
require "webmock/minitest"

class EstimationTargetTest < ActiveSupport::TestCase
  setup do
    # A project of its own: the fixture project's boards would answer first.
    @project = workspaces(:one).projects.create!(name: "Flosis", color: "#123456", external_type: "jira", external_reference: "SCRUM")
  end

  test "names the project's synced boards, else the project" do
    assert_equal @project.name, EstimationTarget.new(@project).board_name

    @project.jira_boards.create!(jira_board_id: 1, name: "SCRUM board", board_type: "simple")

    assert_equal "SCRUM board", EstimationTarget.new(@project).board_name
  end

  test "lists the statuses on the project's boards in column order, each once" do
    board = @project.jira_boards.create!(jira_board_id: 1, name: "SCRUM board", board_type: "simple")
    [ [ "To Do", [ "To Do" ] ], [ "Doing", [ "In Progress", "Blocked" ] ], [ "Done", [ "Done", "To Do" ] ] ].each_with_index do |(name, statuses), position|
      column = board.jira_board_columns.create!(name: name, position: position)
      statuses.each_with_index { |status, i| column.jira_board_column_statuses.create!(jira_status_id: "#{position}#{i}", jira_status_name: status) }
    end

    assert_equal [ "To Do", "In Progress", "Blocked", "Done" ], EstimationTarget.new(@project).statuses
  end

  test "reads the number fields from a project's own Jira" do
    @project.update!(jira_site: "flosis-test.atlassian.net", jira_email: "kacper@example.test", jira_api_token: "t", external_reference: "SCRUM")
    stub_request(:get, "https://flosis-test.atlassian.net/rest/api/3/field").to_return(status: 200, body: [
      { id: "customfield_10016", name: "Story point estimate", custom: true, schema: { type: "number" } }
    ].to_json)
    stub_request(:get, "https://flosis-test.atlassian.net/rest/api/3/project/SCRUM").to_return(status: 200, body: { id: "10000" }.to_json)

    assert_equal [ "Story point estimate" ], EstimationTarget.new(@project).field_names
  end

  # The server's Jira is the first customer's, and the built-in names are its
  # fields: asking it from every Configuration page would buy nothing.
  test "a project on the server's Jira is not asked for its fields" do
    with_env("JIRA_DOMAIN" => "elvium.example.net", "JIRA_EMAIL" => "e@example.com", "JIRA_API_TOKEN" => "t") do
      assert_nil EstimationTarget.new(@project).field_names
    end
    assert_not_requested :get, %r{elvium\.example\.net}
  end

  test "a Jira that can't be read gives no fields" do
    @project.update!(jira_site: "flosis-test.atlassian.net", jira_email: "kacper@example.test", jira_api_token: "t", external_reference: "SCRUM")
    stub_request(:get, "https://flosis-test.atlassian.net/rest/api/3/field").to_return(status: 500, body: "")

    assert_nil EstimationTarget.new(@project).field_names
  end
end
