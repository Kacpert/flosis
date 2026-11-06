# Nightly: a task soft-removed because its Jira issue was deleted
# (JiraSyncService#sync_deleted_issues) goes for good after
# Task::KEPT_AFTER_JIRA_DELETION. Logged time stays — Task nullifies it.
class PurgeJiraDeletedTasksJob < ApplicationJob
  queue_as :default

  def perform
    Task.jira_removed.where(deleted_at: ...Task::KEPT_AFTER_JIRA_DELETION.ago).find_each do |task|
      task.destroy!
    rescue StandardError => e
      # One task that cannot go (a row still pointing at it) must not keep the
      # rest; it is tried again the next night.
      Rails.logger.warn("[PurgeJiraDeletedTasks] task #{task.id} (#{task.external_reference}) kept: #{e.class}: #{e.message}")
    end
  end
end
