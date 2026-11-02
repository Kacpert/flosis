class AddJiraUpdatedAtToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :jira_updated_at, :datetime
    add_index :tasks, [ :project_id, :jira_updated_at ]
  end
end
