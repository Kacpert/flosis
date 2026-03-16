require "test_helper"

class JiraBoardColumnTest < ActiveSupport::TestCase
  test "belongs to jira_board" do
    column = jira_board_columns(:todo_column)
    assert_equal jira_boards(:design_board), column.jira_board
  end

  test "has many statuses" do
    column = jira_board_columns(:todo_column)
    assert column.jira_board_column_statuses.count >= 1
  end

  test "status_names returns array of status names" do
    column = jira_board_columns(:todo_column)
    assert_includes column.status_names, "To Do"
  end

  test "validates presence of required fields" do
    column = JiraBoardColumn.new
    assert_not column.valid?
    assert_includes column.errors[:name], "can't be blank"
    assert_includes column.errors[:position], "can't be blank"
  end
end
