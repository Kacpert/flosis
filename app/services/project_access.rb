# "May this person do this in this project?" — the single place that answers it.
#
# Access has exactly two sources. A workspace admin holds everything in every
# project WITHOUT a membership row: the privilege is global, and deleting a row
# must never be able to lock the workspace away from its own administrator.
# Everyone else holds precisely the switches on their row, and nothing at all
# without one.
class ProjectAccess
  def initialize(user, project)
    @user = user
    @project = project
  end

  def workspace_admin?
    return false unless @user && @project&.workspace

    @user.workspace_admin?(@project.workspace)
  end

  # On the project at all — either by the global privilege or by a row.
  def member?
    workspace_admin? || membership.present?
  end

  def can?(permission)
    name = permission.to_sym
    return false unless PermissionPreset::PERMISSIONS.include?(name)
    return true if workspace_admin?

    membership.present? && membership[name]
  end

  # The switches actually held. A workspace admin reads as all six, which is
  # what the Users grid has to show for them.
  def granted
    return PermissionPreset::PERMISSIONS if workspace_admin?

    membership&.granted || []
  end

  def role_label
    PermissionPreset.label_for(granted)
  end

  private

  # Memoised with defined? rather than ||=, so "no row" is looked up once
  # instead of on every question asked of this object.
  def membership
    return @membership if defined?(@membership)

    @membership = if @user && @project
      ProjectMembership.find_by(user_id: @user.id, project_id: @project.id)
    end
  end
end
