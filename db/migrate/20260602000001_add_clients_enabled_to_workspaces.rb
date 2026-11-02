class AddClientsEnabledToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    # Default OFF: existing and new workspaces start with the Clients tab hidden.
    add_column :workspaces, :clients_enabled, :boolean, null: false, default: false
  end
end
