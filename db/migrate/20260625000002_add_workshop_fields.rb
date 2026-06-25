class AddWorkshopFields < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :features_summary, :text
    add_column :projects, :features_summary_updated_at, :datetime
    add_column :projects, :context_info, :text
    add_column :workspaces, :workshop_enabled, :boolean, null: false, default: false
    add_column :workspaces, :jira_ai_actions_field_id, :string
  end
end
