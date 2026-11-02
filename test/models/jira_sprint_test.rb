require "test_helper"

class JiraSprintTest < ActiveSupport::TestCase
  test "belongs to jira_board" do
    sprint = jira_sprints(:design_sprint)
    assert_equal jira_boards(:design_board), sprint.jira_board
  end

  test "active_or_future scope excludes closed" do
    board = jira_boards(:design_board)
    sprints = board.jira_sprints.active_or_future
    assert sprints.all? { |s| %w[active future].include?(s.state) }
  end

  test "validates presence of required fields" do
    sprint = JiraSprint.new
    assert_not sprint.valid?
    assert_includes sprint.errors[:jira_sprint_id], "can't be blank"
    assert_includes sprint.errors[:name], "can't be blank"
    assert_includes sprint.errors[:state], "can't be blank"
  end

  test "validates state inclusion" do
    sprint = jira_sprints(:design_sprint)
    sprint.state = "invalid"
    assert_not sprint.valid?
  end
end
