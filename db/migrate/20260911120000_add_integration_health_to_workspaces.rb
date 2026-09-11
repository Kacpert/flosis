# Health for the integrations the topbar chips claim to report.
#
# Only GitHub was ever actually checked; Jira, Discord and Figma went green on
# "is it configured?", which is a different question. A Figma token expired
# silently and the first anyone knew of it was the AI telling a client, mid
# conversation, that it couldn't open the design.
class AddIntegrationHealthToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :jira_status_ok, :boolean
    add_column :workspaces, :jira_status_error, :string
    add_column :workspaces, :jira_status_checked_at, :datetime

    add_column :workspaces, :figma_status_ok, :boolean
    add_column :workspaces, :figma_status_error, :string
    add_column :workspaces, :figma_status_checked_at, :datetime
  end
end
