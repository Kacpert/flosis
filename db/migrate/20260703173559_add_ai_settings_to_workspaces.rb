class AddAiSettingsToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :pr_review_prompt, :text
    add_column :workspaces, :figma_read_enabled, :boolean, default: false, null: false
  end
end
