require "test_helper"

class JiraBoardTest < ActiveSupport::TestCase
  test "belongs to project" do
    board = jira_boards(:design_board)
    assert_equal projects(:jira_project), board.project
  end

  test "has many sprints" do
    board = jira_boards(:design_board)
    assert board.jira_sprints.count >= 1
  end

  test "has many columns ordered by position" do
    board = jira_boards(:design_board)
    positions = board.jira_board_columns.pluck(:position)
    assert_equal positions.sort, positions
  end

  test "validates presence of required fields" do
    board = JiraBoard.new
    assert_not board.valid?
    assert_includes board.errors[:jira_board_id], "can't be blank"
    assert_includes board.errors[:name], "can't be blank"
    assert_includes board.errors[:board_type], "can't be blank"
  end

  test "validates board_type inclusion" do
    board = jira_boards(:design_board)
    board.board_type = "invalid"
    assert_not board.valid?
  end

  test "validates uniqueness of jira_board_id within project" do
    existing = jira_boards(:design_board)
    duplicate = JiraBoard.new(
      project: existing.project,
      jira_board_id: existing.jira_board_id,
      name: "Duplicate",
      board_type: "scrum"
    )
    assert_not duplicate.valid?
  end
end
