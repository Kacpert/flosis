require "test_helper"

class DocumentVersioningTest < ActiveSupport::TestCase
  test "make_current! is exclusive per task" do
    task = tasks(:jira_task)
    a = task.briefs.create!(workspace: task.project.workspace, content: "A", version: 1)
    b = task.briefs.create!(workspace: task.project.workspace, content: "B", version: 2)
    b.make_current!
    a.make_current!
    assert a.reload.current?
    refute b.reload.current?
  end

  test "labels derive from origin" do
    task = tasks(:jira_task)
    v = task.briefs.create!(workspace: task.project.workspace, content: "X", version: 1, origin: "user")
    assert_equal "User description", v.label
    v.update!(edited_at: Time.current)
    assert_equal "User description (edited)", v.label
  end

  test "ai drafts get sequential versions per task" do
    task = tasks(:jira_task)
    d1 = task.task_drafts.create!(source: "ai", content: "one")
    d2 = task.task_drafts.create!(source: "ai", content: "two")
    assert_equal d1.version + 1, d2.version
  end
end
