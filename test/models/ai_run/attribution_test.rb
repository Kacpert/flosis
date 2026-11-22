require "test_helper"

class AiRun::AttributionTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:jira_task)
    @user = users(:one)
  end

  test "brief on a pipeline task is a task conversation, breakdown counts as an estimate" do
    @task.update!(in_pipeline: true)
    brief = AiRun::Attribution.for_task_chat(@task, purpose: "brief", user: @user)
    assert_equal "task_conversations", brief.area
    assert_equal "ELV-1 · Briefing", brief.item_label
    assert_equal @task, brief.item
    assert_equal @user, brief.started_by
    assert_equal workspaces(:one), brief.workspace
    assert_equal "estimates", AiRun::Attribution.for_task_chat(@task, purpose: "breakdown", user: @user).area
  end

  test "refine is Details Gathering in the pipeline and the ticket chat outside it" do
    @task.update!(in_pipeline: true)
    details = AiRun::Attribution.for_task_chat(@task, purpose: "refine", user: @user)
    assert_equal [ "task_conversations", "ELV-1 · Details Gathering" ], [ details.area, details.item_label ]

    @task.update!(in_pipeline: false)
    chat = AiRun::Attribution.for_task_chat(@task, purpose: "refine", user: @user)
    assert_equal [ "ticket_chat", "ELV-1 · Chat" ], [ chat.area, chat.item_label ]
  end

  test "a task without a Jira key is named by its id" do
    task = Task.create!(name: "Loose idea", project: projects(:jira_project))
    assert_equal "task-#{task.id}", AiRun::Attribution.task_key(task)
  end

  test "an estimate's label does not repeat a key the task name already starts with" do
    assert_equal "ELV-1 Existing task", AiRun::Attribution.for_estimate(@task).item_label
    assert_equal "AI estimate", AiRun::Attribution.for_estimate(@task).automation
  end

  test "an attribution needs a person or an automation, not both" do
    assert_raises(ArgumentError) { ai_attribution(started_by: @user, automation: "Rule") }
    assert_raises(ArgumentError) { ai_attribution(started_by: nil, automation: nil) }
  end

  test "an unknown area is refused" do
    assert_raises(ArgumentError) { ai_attribution(area: "billing") }
  end

  test "an attribution needs an organization" do
    assert_raises(ArgumentError) { ai_attribution(workspace: nil) }
  end

  include AiRunTestHelper
end
