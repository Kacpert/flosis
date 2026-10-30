require "test_helper"

class Designs::BranchNamesTest < ActiveSupport::TestCase
  test "a Jira task is named after its key" do
    task = Task.new(id: 7, external_reference: "REC-142")
    assert_equal "REC-142", Designs::BranchNames.slug(task)
    assert_equal "wip/REC-142", Designs::BranchNames.wip(task)
    assert_equal "design/REC-142", Designs::BranchNames.design(task)
  end

  test "a task without a Jira issue is named after its id" do
    assert_equal "wip/task-7", Designs::BranchNames.wip(Task.new(id: 7, external_reference: nil))
  end

  test "anything that is not a Jira key falls back to the id" do
    assert_equal "task-7", Designs::BranchNames.slug(Task.new(id: 7, external_reference: "../master"))
  end

  test "approval tags number each approval of a task" do
    assert_equal "approved/REC-142/3", Designs::BranchNames.approval_tag("REC-142", 3)
  end
end
