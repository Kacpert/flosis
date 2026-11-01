require "test_helper"

class Designs::ThreadNamesTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
  end

  test "a thread without a task is named after the first four words of its change" do
    assert_equal "design/let-recruiters-move-several",
                 Designs::ThreadNames.branch_for(project: @project, text: "Let recruiters move several candidates at once")
  end

  test "a thread started from a task carries its Jira key" do
    task = tasks(:jira_task)
    task.update!(project: @project, external_reference: "SP-1051")

    assert_equal "design/SP-1051-inline-validation-on-question",
                 Designs::ThreadNames.branch_for(project: @project, text: "Inline validation on question editor", task: task)
  end

  test "a task without a Jira key is task-<id>" do
    task = tasks(:jira_task)
    task.update!(project: @project, external_reference: nil)

    assert_equal "design/task-#{task.id}-fix-the-header",
                 Designs::ThreadNames.branch_for(project: @project, text: "Fix the header", task: task)
  end

  test "a name the project already has gets a number" do
    DesignThread.create!(project: @project, author: users(:one), title: "x", branch: "design/fix-the-header")

    assert_equal "design/fix-the-header-2", Designs::ThreadNames.branch_for(project: @project, text: "Fix the header")
  end

  test "text with nothing to name it by still gives a branch" do
    assert_equal "design/change", Designs::ThreadNames.branch_for(project: @project, text: "!!!")
  end

  test "Polish letters become plain ones" do
    assert_equal "design/zolta-lodz-na-starcie", Designs::ThreadNames.branch_for(project: @project, text: "Żółta łódź na starcie aplikacji")
  end
end
