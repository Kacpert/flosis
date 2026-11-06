# A Jira-mirrored task whose issue was deleted in Jira is soft-removed: hidden
# at once, purged after 30 days (PurgeJiraDeletedTasksJob), restored if the
# issue comes back. See JiraSyncService#sync_deleted_issues.
class AddDeletedAtToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :deleted_at, :datetime
    add_index :tasks, :deleted_at
  end
end
