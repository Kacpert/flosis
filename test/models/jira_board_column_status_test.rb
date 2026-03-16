require "test_helper"

class JiraBoardColumnStatusTest < ActiveSupport::TestCase
  test "belongs to jira_board_column" do
    status = jira_board_column_statuses(:todo_status)
    assert_equal jira_board_columns(:todo_column), status.jira_board_column
  end

  test "validates presence of required fields" do
    status = JiraBoardColumnStatus.new
    assert_not status.valid?
    assert_includes status.errors[:jira_status_name], "can't be blank"
    assert_includes status.errors[:jira_status_id], "can't be blank"
  end
end
