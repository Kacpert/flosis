require "test_helper"

class DesignThreadTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @task = tasks(:jira_task)
    @task.update!(project: @project)
  end

  test "a task has at most one thread" do
    DesignThread.create!(project: @project, task: @task, author: users(:one), title: "A")
    second = DesignThread.new(project: @project, task: @task, author: users(:one), title: "B")

    assert_not second.valid?
  end

  test "a thread outlives its task" do
    thread = DesignThread.create!(project: @project, task: @task, author: users(:one), title: "A")
    @task.destroy!

    assert_nil thread.reload.task_id
  end

  test "a thread is open and fresh until it is named, and merged once merged" do
    thread = DesignThread.create!(project: @project, author: users(:one), title: "New thread")
    assert thread.fresh?
    assert thread.open?
    assert_includes DesignThread.open, thread

    thread.update!(branch: "design/x", status: "merged", merged_sha: "abc1234", merged_at: Time.current)
    assert thread.merged?
    assert_not thread.fresh?
    assert_includes DesignThread.merged, thread
  end

  test "a merge says how it landed, in the design's words" do
    @task.update!(external_reference: "SP-1040")
    base = { project: @project, sha: "a3f9c21", title: "Stage colours", branch: "design/x", merged_at: Time.current }

    assert_equal "Manual · #{users(:one).name}", DesignMerge.new(base.merge(how: "manual", user: users(:one))).how_label
    assert_equal "Auto · SP-1040 moved to Done", DesignMerge.new(base.merge(how: "auto", task: @task)).how_label
    assert_equal "Flosis AI · setup", DesignMerge.new(base.merge(how: "setup")).how_label
  end
end
