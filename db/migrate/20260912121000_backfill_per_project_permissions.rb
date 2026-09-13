# Translates the old five-value role into the new switches.
#
# Written in Ruby, not SQL: production is MySQL and the row-by-row shape is the
# same either way, so there is nothing to gain from a clever UPDATE that then
# has to be written twice.
class BackfillPerProjectPermissions < ActiveRecord::Migration[8.1]
  # The old enum, by the integer actually stored in the column. Read by value
  # because the enum itself is removed from the model in this same release.
  EMPLOYEE = 0
  ADMIN = 1
  OWNER = 2
  CLIENT = 3
  WORKSPACE_CLIENT = 4

  def up
    WorkspaceMembership.reset_column_information
    ProjectMembership.reset_column_information

    say_with_time "translating roles into per-project permissions" do
      WorkspaceMembership.find_each do |membership|
        case membership.read_attribute_before_type_cast(:role)
        when ADMIN, OWNER then promote_to_workspace_admin(membership)
        when CLIENT then grant(membership, %i[tasks], revoke_hr: true)
        when WORKSPACE_CLIENT then grant(membership, PermissionPreset::PRESETS.fetch("Product Owner"))
        else grant(membership, employee_permissions(membership))
        end
      end
    end
  end

  # Release one keeps the old columns, so there is nothing to restore.
  def down; end

  private

  def employee_permissions(membership)
    return [] unless membership.read_attribute(:workshop_access)

    PermissionPreset::PRESETS.fetch("Project Manager")
  end

  # No rows are created for an admin — their access is the flag. Rows they
  # already have get every switch on so the Users grid does not lie.
  def promote_to_workspace_admin(membership)
    membership.update_columns(workspace_admin: true)
    rows_for(membership).update_all(PermissionPreset::PERMISSIONS.index_with(true))
  end

  def grant(membership, permissions, revoke_hr: false)
    membership.update_columns(workspace_admin: false)
    membership.update_columns(time_hr_access: false) if revoke_hr
    rows_for(membership).update_all(
      PermissionPreset::PERMISSIONS.index_with { |permission| permissions.include?(permission) }
    )
  end

  def rows_for(membership)
    ProjectMembership.where(
      user_id: membership.user_id,
      project_id: Project.where(workspace_id: membership.workspace_id).select(:id)
    )
  end
end
