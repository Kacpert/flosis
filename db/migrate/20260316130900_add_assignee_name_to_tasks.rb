class AddAssigneeNameToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :assignee_name, :string
    add_column :tasks, :reporter_name, :string
  end
end
