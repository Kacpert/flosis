require "test_helper"

class JiraSyncServiceBoardsTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
  end

  def build_mock_client(boards: [], board_configs: {}, sprints: {}, issues: [])
    boards_data = boards
    configs = board_configs
    sprints_data = sprints
    issues_data = issues
    project_key = @project.external_reference

    Class.new do
      define_method(:fetch_boards) { |_key| boards_data }

      define_method(:fetch_board_configuration) do |board_id|
        configs[board_id] || []
      end

      define_method(:fetch_sprints) do |board_id|
        sprints_data[board_id] || []
      end

      define_method(:fetch_issues) { |_key| issues_data }
    end.new
  end

  test "syncs boards from Jira" do
    client = build_mock_client(
      boards: [{ id: 201, name: "New Board", type: "kanban" }],
      board_configs: { 201 => [{ name: "Todo", statuses: [{ id: "1" }] }] }
    )

    JiraSyncService.new(@project, client: client).sync

    board = @project.jira_boards.find_by(jira_board_id: 201)
    assert board.present?
    assert_equal "New Board", board.name
    assert_equal "kanban", board.board_type
  end

  test "updates existing boards" do
    client = build_mock_client(
      boards: [{ id: 101, name: "Design Renamed", type: "scrum" }],
      board_configs: { 101 => [{ name: "Todo", statuses: [{ id: "1" }] }] }
    )

    JiraSyncService.new(@project, client: client).sync

    board = jira_boards(:design_board).reload
    assert_equal "Design Renamed", board.name
  end

  test "syncs board columns and statuses" do
    client = build_mock_client(
      boards: [{ id: 101, name: "Design", type: "scrum" }],
      board_configs: {
        101 => [
          { name: "TODO", statuses: [{ id: "10001" }, { id: "10004" }] },
          { name: "DONE", statuses: [{ id: "10003" }] }
        ]
      }
    )

    JiraSyncService.new(@project, client: client).sync

    board = @project.jira_boards.find_by(jira_board_id: 101)
    assert_equal 2, board.jira_board_columns.count
    todo_col = board.jira_board_columns.find_by(name: "TODO")
    assert_equal 0, todo_col.position
    assert_equal 2, todo_col.jira_board_column_statuses.count
  end

  test "syncs sprints" do
    client = build_mock_client(
      boards: [{ id: 101, name: "Design", type: "scrum" }],
      board_configs: { 101 => [] },
      sprints: {
        101 => [
          { id: 999, name: "New Sprint", state: "future", start_date: nil, end_date: nil }
        ]
      }
    )

    JiraSyncService.new(@project, client: client).sync

    board = @project.jira_boards.find_by(jira_board_id: 101)
    sprint = board.jira_sprints.find_by(jira_sprint_id: 999)
    assert sprint.present?
    assert_equal "New Sprint", sprint.name
    assert_equal "future", sprint.state
  end

  test "removes stale boards" do
    assert @project.jira_boards.find_by(jira_board_id: 102).present?

    client = build_mock_client(
      boards: [{ id: 101, name: "Design", type: "scrum" }],
      board_configs: { 101 => [] }
    )

    JiraSyncService.new(@project, client: client).sync

    assert_nil @project.jira_boards.find_by(jira_board_id: 102)
  end

  test "syncs extended issue fields" do
    client = build_mock_client(
      issues: [
        {
          key: "ELV-1",
          summary: "Existing task updated",
          status_category: "indeterminate",
          status_name: "In Progress",
          assignee_email: "one@example.com",
          url: "https://elvium.atlassian.net/browse/ELV-1",
          description: "Updated description",
          priority: "Medium",
          issue_type: "Bug",
          labels: ["backend"],
          reporter_email: "reporter@example.com",
          sprint_id: 569,
          sprint_name: "Design Sprint",
          time_estimate_seconds: 1800
        }
      ]
    )

    JiraSyncService.new(@project, client: client).sync

    task = tasks(:jira_task).reload
    assert_equal "Updated description", task.description
    assert_equal "Medium", task.priority
    assert_equal "Bug", task.issue_type
    assert_equal '["backend"]', task.labels
    assert_equal "reporter@example.com", task.reporter_email
    assert_equal 569, task.sprint_id
    assert_equal "Design Sprint", task.sprint_name
    assert_equal 1800, task.time_estimate_seconds
  end
end
