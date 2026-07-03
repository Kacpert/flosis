module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace
    before_action :redirect_clients_to_jira
    before_action :set_running_timer
    helper_method :current_workspace
    helper_method :available_projects
    helper_method :current_product
    helper_method :current_workshop_project
    helper_method :workshop_projects
  end

  PRODUCTS = %w[time_hr workshop].freeze

  private

  def current_workspace
    Current.workspace
  end

  # The product the user is currently viewing (:time_hr or :workshop). Honors
  # the session choice when the user still has access; otherwise falls back to
  # their default accessible product. Persists the resolved value.
  def current_product
    return @current_product if defined?(@current_product)
    return @current_product = nil unless current_workspace && current_user

    chosen = session[:product]&.to_sym
    resolved = if chosen && current_user.can_access_product?(current_workspace, chosen)
      chosen
    else
      current_user.default_product(current_workspace)
    end

    session[:product] = resolved&.to_s
    @current_product = resolved
  end

  # Landing path for a product (or the current one when nil given). Clients are
  # Jira-Tasks-only, so the Workshop landing for them is the Jira board.
  def product_landing_path(product = current_product)
    return time_entries_path unless product&.to_sym == :workshop
    return jira_tasks_path if current_user&.client_role?(current_workspace)

    workshop_pipeline_path
  end

  # The Jira-connected projects that form the Workshop "work context" — the same
  # set the Jira board / Workshop pipeline operate on, scoped to what the user
  # can see (admins: all; others: their project memberships).
  def workshop_projects
    return @workshop_projects if defined?(@workshop_projects)
    scope = current_workspace.projects.active.where(external_type: "jira")
    scope = scope.joins(:project_memberships)
                 .where(project_memberships: { user_id: current_user.id }) unless current_user.admin_or_owner?(current_workspace)
    @workshop_projects = scope.order(:name)
  end

  # The active Workshop project context (a project switcher, like the workspace
  # switcher). Honors the session choice when still visible; else the first
  # visible Jira project. Persists the resolved id.
  def current_workshop_project
    return @current_workshop_project if defined?(@current_workshop_project)
    projects = workshop_projects
    chosen = projects.find_by(id: session[:workshop_project_id]) || projects.first
    session[:workshop_project_id] = chosen&.id
    @current_workshop_project = chosen
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

  # The "Switch Back" escape hatch for an impersonating admin must never be
  # trapped, otherwise an admin who is viewing-as a client gets bounced back to
  # Jira Tasks and can never restore their own session.
  CLIENT_ALLOWED_EXACT_PATHS = ["/stop_impersonating"].freeze

  def redirect_clients_to_jira
    return unless Current.workspace
    return unless current_user&.client_role?(Current.workspace)
    return if CLIENT_ALLOWED_EXACT_PATHS.include?(request.path)
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
