module WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace
    before_action :set_running_timer
    helper_method :current_workspace
    helper_method :available_projects
    helper_method :current_product
    helper_method :current_workshop_project
    helper_method :resolved_workshop_project
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

  # Landing path for a product. For the Workshop that is whichever page this
  # person can actually open — see workshop_landing_path. Returning the
  # pipeline unconditionally would send someone who lacks Tasks to a page that
  # immediately refuses them.
  #
  # No product at all is the same question workshop_landing_path answers for
  # someone holding no permission, so it gets the same answer: the profile,
  # gated by neither product. Time & HR was the old answer, and
  # require_employee! bounced them straight back to root.
  def product_landing_path(product = current_product)
    return profile_path unless product
    return time_entries_path unless product.to_sym == :workshop

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

  # The projects forming the Workshop work context: the project switcher, and
  # via current_workshop_project below, what require_project_member! and
  # every require_permission! check actually run against. Deliberately NOT
  # visible_jira_projects (Authorization) — that scope is Tasks-specific (the
  # Jira board's "which projects can I work tickets in"), and reusing it here
  # left current_workshop_project unresolvable for anyone holding Automations,
  # Reporting or Configuration but not Tasks: their membership would never
  # match, so can?() saw no project at all and always answered false,
  # regardless of what they were actually granted. This scope is any membership
  # that grants SOMETHING — the individual page still asks for the permission
  # it needs once a project is selected. Not existence alone: a row with all
  # six switches off is how an HR-only employee's hours attach to a project,
  # and offering that project made it current_workshop_project, where every
  # page refused them in turn.
  #
  # No `external_type: "jira"` filter either. That one dated from when the
  # Workshop was Jira-shaped; under per-project configuration a project with no
  # Jira still has automations, reporting, pricing, users, Discord and PR
  # review. It made a project created with "Set up later" unreachable by any
  # url, and left a workspace holding no Jira project with no openable Workshop
  # page at all — so the dialog that creates projects was itself out of reach.
  #
  # `.in_workshop` is the last filter here and applies to the admin too: a
  # project that says it does not belong in Flosis does not belong in anyone's
  # switcher. Time tracking is deliberately unaffected — available_projects
  # below does not consult it, because an HR stub exists precisely so hours can
  # attach to it. Hiding every project leaves no openable Workshop page, and
  # the way back is Time & HR -> the project, which lists them all.
  def workshop_projects
    scope = current_workspace.projects.active.in_workshop
    return scope.order(:name) if workspace_admin?

    scope.joins(:project_memberships)
         .where(project_memberships: { user_id: current_user&.id })
         .merge(ProjectMembership.granting_anything)
         .order(:name)
  end

  # The active Workshop project context (a project switcher, like the workspace
  # switcher). Honors the session choice when still visible; else the first
  # visible project. Persists the resolved id.
  def current_workshop_project
    return @current_workshop_project if defined?(@current_workshop_project)

    chosen = resolved_workshop_project
    session[:workshop_project_id] = chosen&.id
    @current_workshop_project = chosen
  end

  # The same resolution WITHOUT choosing: nothing is written to the session.
  # For callers that merely want to look — the admin GitHub banner is a layout
  # gate on every page in the HR layout, and viewing a timesheet must not
  # decide which project the Workshop opens on.
  def resolved_workshop_project
    return @resolved_workshop_project if defined?(@resolved_workshop_project)

    projects = workshop_projects
    @resolved_workshop_project = projects.find_by(id: session[:workshop_project_id]) || projects.first
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
