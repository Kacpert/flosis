require "test_helper"

class TaskDraftTest < ActiveSupport::TestCase
  setup { @task = tasks(:jira_task) }

  test "latest_draft returns only ai-source drafts" do
    @task.task_drafts.create!(content: "refined v1", source: TaskDraft::REFINE_SOURCE)
    @task.task_drafts.create!(content: '{"total_points":3}', source: TaskDraft::BREAKDOWN_SOURCE)
    refined = @task.task_drafts.create!(content: "refined v2", source: TaskDraft::REFINE_SOURCE)

    assert_equal refined.id, @task.latest_draft.id
    assert_equal "refined v2", @task.latest_draft.content
  end

  test "latest_breakdown returns only breakdown-source drafts" do
    @task.task_drafts.create!(content: "refined", source: TaskDraft::REFINE_SOURCE)
    bd = @task.task_drafts.create!(content: '{"total_points":5}', source: TaskDraft::BREAKDOWN_SOURCE)

    assert_equal bd.id, @task.latest_breakdown.id
  end

  test "by_source scope filters" do
    @task.task_drafts.create!(content: "a", source: TaskDraft::REFINE_SOURCE)
    @task.task_drafts.create!(content: "b", source: TaskDraft::BREAKDOWN_SOURCE)

    assert_equal 1, @task.task_drafts.by_source(TaskDraft::REFINE_SOURCE).count
    assert_equal 1, @task.task_drafts.by_source(TaskDraft::BREAKDOWN_SOURCE).count
  end

  test "latest_breakdown is nil when none exist" do
    assert_nil @task.latest_breakdown
  end
end
