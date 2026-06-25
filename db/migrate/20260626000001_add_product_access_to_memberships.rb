class AddProductAccessToMemberships < ActiveRecord::Migration[8.1]
  def up
    add_column :workspace_memberships, :time_hr_access, :boolean, null: false, default: true
    add_column :workspace_memberships, :workshop_access, :boolean, null: false, default: false

    # Backfill: admins/owners get both products; employees get Time & HR only;
    # clients are governed by role rules (Jira-Tasks-only), leave defaults.
    execute <<~SQL
      UPDATE workspace_memberships SET workshop_access = TRUE WHERE role IN (1, 2)
    SQL
  end

  def down
    remove_column :workspace_memberships, :time_hr_access
    remove_column :workspace_memberships, :workshop_access
  end
end
