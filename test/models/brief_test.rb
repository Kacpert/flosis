require "test_helper"

class BriefTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:jira_task)
    @workspace = @task.project.workspace
  end

  test "next_version_for starts at 1 and increments" do
    assert_equal 1, Brief.next_version_for(@task)
    Brief.create!(task: @task, workspace: @workspace, version: 1, content: "v1")
    assert_equal 2, Brief.next_version_for(@task)
  end

  test "mark_briefed! sets status and timestamp" do
    b = Brief.create!(task: @task, workspace: @workspace, version: 1, content: "x")
    assert_equal "draft", b.status
    b.mark_briefed!
    assert_equal "briefed", b.status
    assert_not_nil b.briefed_at
  end

  test "latest_brief returns the most recent" do
    Brief.create!(task: @task, workspace: @workspace, version: 1, content: "old")
    newer = Brief.create!(task: @task, workspace: @workspace, version: 2, content: "new")
    assert_equal newer, @task.latest_brief
  end
end
