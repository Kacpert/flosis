module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace
    before_action :set_running_timer
    helper_method :current_workspace
    helper_method :available_projects
  end

  private

  def current_workspace
    Current.workspace
  end

  def available_projects
    if current_user.admin_or_owner?(current_workspace)
      current_workspace.projects.active.order(:name)
    else
      current_workspace.projects.active
        .joins(:project_memberships)
        .where(project_memberships: { user_id: current_user.id })
        .order(:name)
    end
  end

  def set_current_workspace
    Current.workspace = current_user.workspaces.find_by(id: session[:workspace_id]) ||
                        current_user.workspaces.first

    if Current.workspace
      session[:workspace_id] = Current.workspace.id
    else
      redirect_to new_workspace_path
    end
  end


  def set_running_timer
    return unless Current.workspace
    @running_timer = Current.user
      .time_entries
      .where(workspace: Current.workspace, stopped_at: nil)
      .includes(:tags, :task, :project)
      .first
  end

  def current_user
    Current.user
  end
end
