module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace
    before_action :redirect_clients_to_jira
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


  # Clients may only use the Jira Tasks area (plus profile / session). Any other
  # page is redirected to Jira Tasks. Runs after the workspace is set and before
  # the per-controller role guards; never redirects a request already under an
  # allowed prefix, so there is no loop.
  CLIENT_ALLOWED_PREFIXES = ["/jira_tasks", "/profile", "/session"].freeze

  def redirect_clients_to_jira
    return unless Current.workspace
    return unless current_user&.client_role?(Current.workspace)
    return if CLIENT_ALLOWED_PREFIXES.any? { |p| request.path == p || request.path.start_with?("#{p}/") }

    redirect_to jira_tasks_path
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
