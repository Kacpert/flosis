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
    host_default = product_for_host

    resolved = if chosen && current_user.can_access_product?(current_workspace, chosen)
      chosen
    elsif host_default && current_user.can_access_product?(current_workspace, host_default)
      host_default
    else
      current_user.default_product(current_workspace)
    end

    session[:product] = resolved&.to_s
    @current_product = resolved
  end

  # The hostname picks which product you LAND on. The app now answers on
  # app.flosis.com (which matches FLOSIS_HOST's `*.flosis.com`), so in practice
  # this resolves to Flosis; the fallback branch survives for local and staging
  # hostnames, where the user's own default applies. It's only a default — the
  # product switcher still wins.
  def product_for_host
    :workshop if flosis_host?
  end

  def flosis_host?
    root = ENV.fetch("FLOSIS_HOST", "flosis.com").downcase
    host = request&.host.to_s.downcase
    host == root || host.end_with?(".#{root}")
  end

  # Landing path for a product (or the current one when nil given). Clients are
  # Jira-Tasks-only, so the Workshop landing for them is the Jira board.
  def product_landing_path(product = current_product)
    return time_entries_path unless product&.to_sym == :workshop
    return jira_tasks_path if current_user&.client_role?(current_workspace)

    workshop_landing_path
  end

  # The first Workshop page this person can actually open. Every entry here
  # must be a page whose own gate this branch has just proved, otherwise the
  # redirect bounces and the browser gives up with too many redirects. Someone
  # holding no Workshop permission at all gets their profile, which is gated by
  # neither product.
  def workshop_landing_path
    return workshop_pipeline_path if can?(:tasks)
    return workshop_process_path if can?(:automations)
    return workshop_reporting_path if can?(:reporting)
    return workshop_configuration_path if can?(:configuration) || can?(:briefing_config)

    profile_path
  end

  # The Jira projects forming the Workshop work context: the project switcher,
  # and via current_workshop_project below, what require_project_member! and
  # every require_permission! check actually run against. Deliberately NOT
  # visible_jira_projects (Authorization) — that scope is Tasks-specific (the
  # Jira board's "which projects can I work tickets in"), and reusing it here
  # left current_workshop_project unresolvable for anyone holding Automations,
  # Reporting or Configuration but not Tasks: their membership would never
  # match, so can?() saw no project at all and always answered false,
  # regardless of what they were actually granted. This scope is any
  # membership at all — the individual page still asks for the permission it
  # needs once a project is selected.
  def workshop_projects
    scope = current_workspace.projects.active.where(external_type: "jira")
    return scope.order(:name) if workspace_admin?

    scope.joins(:project_memberships)
         .where(project_memberships: { user_id: current_user&.id })
         .order(:name)
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

  # Projects this person may book time against. A workspace admin sees every
  # one; everyone else sees the projects they are on. Deliberately NOT
  # visible_jira_projects, which additionally requires the Tasks permission —
  # booking hours is an HR action and must not need Workshop standing.
  def available_projects
    return current_workspace.projects.active.order(:name) if workspace_admin?

    current_workspace.projects.active
      .joins(:project_memberships)
      .where(project_memberships: { user_id: current_user.id })
      .order(:name)
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
