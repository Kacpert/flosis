class RemoveDeprecatedColumns < ActiveRecord::Migration[8.1]
  def change
    # Add NOT NULL constraint on time_entries.project_id
    change_column_null :time_entries, :project_id, false

    remove_column :workspaces, :default_currency, :string
    remove_column :workspaces, :default_hourly_rate_cents, :integer
    remove_column :workspaces, :week_start, :integer
    remove_column :workspaces, :time_format, :integer
    remove_column :projects, :hourly_rate_cents, :integer
    remove_column :projects, :billable, :boolean
    remove_column :tasks, :hourly_rate_cents, :integer
    remove_column :tasks, :billable, :boolean
    remove_column :users, :default_hourly_rate_cents, :integer
    remove_column :time_entries, :billable, :boolean
  end
end
