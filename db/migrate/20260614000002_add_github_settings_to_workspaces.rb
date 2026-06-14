class AddGithubSettingsToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :github_token, :string
    add_column :workspaces, :github_repo, :string
    add_column :workspaces, :pr_review_enabled, :boolean, null: false, default: false
    add_column :workspaces, :github_status_ok, :boolean
    add_column :workspaces, :github_status_checked_at, :datetime
    add_column :workspaces, :github_status_error, :string
  end
end
