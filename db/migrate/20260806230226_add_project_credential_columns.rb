class AddProjectCredentialColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :github_repo, :string unless column_exists?(:projects, :github_repo)
    add_column :projects, :github_token, :text unless column_exists?(:projects, :github_token)
    add_column :projects, :jira_site, :string unless column_exists?(:projects, :jira_site)
    add_column :projects, :jira_email, :string unless column_exists?(:projects, :jira_email)
    add_column :projects, :jira_api_token, :text unless column_exists?(:projects, :jira_api_token)
    add_column :projects, :workspace_dir, :string unless column_exists?(:projects, :workspace_dir)
    add_column :projects, :repo_checkout_status, :string unless column_exists?(:projects, :repo_checkout_status)
    add_column :projects, :repo_checkout_error, :string unless column_exists?(:projects, :repo_checkout_error)
    add_column :projects, :mcp_synced_at, :datetime unless column_exists?(:projects, :mcp_synced_at)
  end
end
