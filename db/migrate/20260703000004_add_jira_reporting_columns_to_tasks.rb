class AddJiraReportingColumnsToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :story_points, :decimal, precision: 5, scale: 1
    add_column :tasks, :jira_created_at, :datetime
  end
end
