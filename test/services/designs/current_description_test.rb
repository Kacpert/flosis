require "test_helper"

class Designs::CurrentDescriptionTest < ActiveSupport::TestCase
  setup { @task = tasks(:jira_task) }

  test "the details draft wins over the brief and the description" do
    @task.update!(description: "from jira")
    @task.briefs.create!(workspace: @task.project.workspace, version: 1, content: "brief", origin: "ai").make_current!
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, content: "draft", origin: "ai").make_current!
    assert_equal "draft", Designs::CurrentDescription.for(@task)
  end

  test "the brief wins over the description" do
    @task.update!(description: "from jira")
    @task.briefs.create!(workspace: @task.project.workspace, version: 1, content: "brief", origin: "ai").make_current!
    assert_equal "brief", Designs::CurrentDescription.for(@task)
  end

  test "falls back to the task's description" do
    @task.update!(description: "from jira")
    assert_equal "from jira", Designs::CurrentDescription.for(@task)
  end

  test "an estimate breakdown is not a description" do
    @task.update!(description: "from jira")
    @task.task_drafts.create!(source: TaskDraft::BREAKDOWN_SOURCE, content: '{"total_points":5}', origin: "ai").make_current!
    assert_equal "from jira", Designs::CurrentDescription.for(@task)
  end

  test "a task with nothing written about it has no description" do
    [ nil, "", "  " ].each do |blank|
      @task.update!(description: blank)
      assert_nil Designs::CurrentDescription.for(@task), blank.inspect
    end
  end
end
