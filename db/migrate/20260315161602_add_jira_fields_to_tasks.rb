class AddJiraFieldsToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :assignee_email, :string
    add_column :tasks, :jira_status_name, :string
    add_index :tasks, [:project_id, :external_type, :external_reference], unique: true,
              name: "index_tasks_on_project_external_ref"
  end
end
