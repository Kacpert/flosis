class AddDetailFieldsToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :description, :text
    add_column :tasks, :priority, :string
    add_column :tasks, :issue_type, :string
    add_column :tasks, :labels, :text
    add_column :tasks, :reporter_email, :string
    add_column :tasks, :sprint_name, :string
    add_column :tasks, :sprint_id, :integer
    add_column :tasks, :time_estimate_seconds, :integer
  end
end
