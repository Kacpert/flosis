require "test_helper"

# An issue deleted in Jira: its task in Create Tasks keeps its work as a local
# idea; any other Jira task is soft-removed, then purged after 30 days.
class TaskJiraDeletionTest < ActiveSupport::TestCase
  test "a soft-removed task is no longer one of the project's Jira tasks" do
    task = tasks(:jira_task)
    task.remove_deleted_jira_issue!

    assert task.deleted_at.present?
    assert_not_includes task.project.tasks.jira_synced, task
    assert_includes Task.jira_removed, task
  end

  test "kept leaves soft-removed tasks out" do
    task = tasks(:jira_task)
    task.remove_deleted_jira_issue!

    assert_not_includes Task.kept, task
    assert_includes Task.kept, tasks(:local_task)
  end

  test "a task in Create Tasks becomes a local idea instead, keeping its work" do
    task = tasks(:jira_task) # "ELV-1 Existing task", key ELV-1
    task.update!(in_pipeline: true, workshop_stage: "details", description: "The ticket text")
    task.briefs.create!(workspace: task.project.workspace, version: 1, origin: "ai", status: "briefed", content: "b")

    task.remove_deleted_jira_issue!
    task.reload

    assert_nil task.deleted_at
    assert_nil task.external_type
    assert_nil task.external_reference
    assert_nil task.external_url
    assert_equal "Existing task", task.name
    assert_equal "The ticket text", task.description
    assert task.in_pipeline?
    assert_equal "details", task.workshop_stage
    assert_equal 1, task.briefs.count
    assert_includes Task.local_only, task
  end

  test "a local idea keeps its key in the name when the bare title is already taken" do
    task = tasks(:jira_task)
    task.update!(in_pipeline: true, workshop_stage: "briefing")
    task.project.tasks.create!(name: "Existing task")

    task.remove_deleted_jira_issue!

    assert_equal "ELV-1 Existing task", task.reload.name
    assert_nil task.external_reference
  end

  test "restore brings a soft-removed task back" do
    task = tasks(:jira_task)
    task.remove_deleted_jira_issue!

    Task.jira_removed.restore_all

    assert_nil task.reload.deleted_at
    assert_includes task.project.tasks.jira_synced, task
  end

  test "the purge deletes tasks soft-removed over 30 days ago and keeps their logged time" do
    old = tasks(:jira_task)
    old.update!(deleted_at: 31.days.ago)
    entry = TimeEntry.create!(user: users(:one), project: old.project, workspace: workspaces(:one), task: old,
                              started_at: 2.hours.ago, stopped_at: 1.hour.ago)

    PurgeJiraDeletedTasksJob.perform_now

    assert_not Task.exists?(old.id)
    assert TimeEntry.exists?(entry.id), "the logged time stays"
    assert_nil entry.reload.task_id
  end

  test "the purge keeps a task soft-removed less than 30 days ago" do
    recent = tasks(:jira_task)
    recent.update!(deleted_at: 29.days.ago)

    PurgeJiraDeletedTasksJob.perform_now

    assert Task.exists?(recent.id)
  end

  test "the purge never touches a task that was not removed" do
    PurgeJiraDeletedTasksJob.perform_now

    assert Task.exists?(tasks(:jira_task).id)
    assert Task.exists?(tasks(:local_task).id)
  end

  test "the purge runs nightly in production" do
    jobs = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).deep_symbolize_keys.fetch(:production)
    entry = jobs.values.find { |job| job[:class] == "PurgeJiraDeletedTasksJob" }

    assert entry, "PurgeJiraDeletedTasksJob is not scheduled"
    assert_match(/\A\d+ \d+ \* \* \*\z/, entry[:schedule])
  end
end
