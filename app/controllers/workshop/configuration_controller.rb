# Configuration: per-project credentials, AI behaviour and access. Each tab
# costs a permission (see TAB_PERMISSIONS); the page opens for anyone holding
# either of the two the tabs use, and a tab you lack renders locked instead of
# missing.
class Workshop::ConfigurationController < Workshop::BaseController
  TABS = %w[integrations ai briefing users].freeze

  AI_FIELDS = %i[
    pr_review_prompt pr_poll_minutes pr_review_enabled
    estimation_trigger estimation_status_trigger figma_read_enabled anthropic_api_key
  ].freeze

  INTEGRATION_FIELDS = {
    "jira" => %i[jira_site jira_email jira_api_token external_reference],
    "github" => %i[github_repo github_token pr_review_enabled],
    "figma" => %i[figma_token figma_read_enabled]
  }.freeze

  # A blank secret means "leave it alone", never "erase it" — the forms render
  # secrets as empty fields, so submitting the page untouched must not wipe the
  # keys.
  SECRETS = %i[jira_api_token github_token figma_token anthropic_api_key].freeze

  # What each tab costs. Briefing is the one a Product Owner holds, which is
  # why this is a per-tab map and not a single gate on the page.
  TAB_PERMISSIONS = {
    "integrations" => :configuration,
    "ai" => :configuration,
    "briefing" => :briefing_config,
    "users" => :configuration
  }.freeze

  before_action :require_configuration_access!
  before_action -> { require_permission!(:configuration) }, only: %i[test_github verify_jira_fields]
  before_action -> { require_permission!(:briefing_config) }, only: :refresh_features
  before_action :redirect_to_a_tab_they_hold, only: :show

  def show
    @tab = requested_tab
    load_ai_tab if @tab == "ai"
    load_briefing_tab if @tab == "briefing"
    load_integrations_tab if @tab == "integrations"
    load_users_tab if @tab == "users"
  end

  def update
    tab = requested_tab
    return head :forbidden unless tab_permitted?(tab)

    project = current_workshop_project
    return redirect_with("No project selected.", tab) unless project

    case tab
    when "ai" then save_project_fields(project, AI_FIELDS, "AI settings saved")
    when "integrations" then save_integration(project)
    when "briefing" then save_briefing(project)
    end

    redirect_to workshop_configuration_path(tab: tab)
  end

  def test_github
    project = current_workshop_project
    return redirect_with("No project selected.", "integrations") unless project

    result = GithubClient.for_project(project).health_check
    project.update_columns(
      github_status_ok: result[:ok],
      github_status_error: result[:error],
      github_status_checked_at: Time.current
    )
    flash[:clar_toast] = result[:ok] ? "GitHub connection OK." : "GitHub connection failed: #{result[:error]}"
    redirect_to workshop_configuration_path(tab: "integrations")
  end

  # Resolves + caches the 3 Jira custom field ids used by the AI (estimation
  # write target, story points mirror, and AI-actions status field) via the
  # same JiraClient#fetch_field_id lookup JiraWriter/resolve_story_points_field
  # already use elsewhere. Always re-resolves (doesn't short-circuit on an
  # existing cached id) since this action exists specifically to let an admin
  # re-verify/refresh the mapping.
  def verify_jira_fields
    project = current_workshop_project
    return redirect_with("No project selected.", "integrations") unless project

    client = JiraClient.new
    project.update!(
      jira_ai_actions_field_id: client.fetch_field_id("AI actions"),
      jira_ai_estimation_field_id: client.fetch_field_id("AI estimation"),
      jira_story_points_field_id: client.fetch_field_id("Story point estimate") || client.fetch_field_id("Story Points")
    )
    flash[:clar_toast] = "Jira fields verified"
    redirect_to workshop_configuration_path(tab: "integrations")
  end

  # Manually re-scan the current project's feature summary (the auto-maintained
  # "what the app already does" reference for the briefing chat). Enqueued so the
  # request returns immediately — the scan reads the repo and can take a while.
  def refresh_features
    if current_workshop_project
      ProjectFeaturesScanJob.perform_later(current_workshop_project.id)
      flash[:clar_toast] = "Refreshing the app feature summary — this runs in the background."
    else
      flash[:alert] = "No project selected."
    end
    redirect_to workshop_configuration_path(tab: "briefing")
  end

  private

  # The page opens for either permission; with neither there is nothing on it.
  def require_configuration_access!
    return if can?(:configuration) || can?(:briefing_config)

    deny_access!("You don't have permission to access this page.", product_landing_path)
  end

  def requested_tab
    TABS.include?(params[:tab]) ? params[:tab] : default_tab
  end

  # The first tab this person actually holds, so the bare URL never lands on a
  # padlock.
  def default_tab
    can?(:configuration) ? "ai" : "briefing"
  end

  # What a tab costs, with a default, so an unpriced tab lands on the strictest
  # permission rather than on nil. The padlock in the view reads it through
  # here instead of indexing TAB_PERMISSIONS itself: two readings of the same
  # constant is how the lock and the gate come to disagree.
  def tab_permission(tab)
    TAB_PERMISSIONS.fetch(tab, :configuration)
  end
  helper_method :tab_permission

  def tab_permitted?(tab)
    can?(tab_permission(tab))
  end
  helper_method :tab_permitted?

  def redirect_to_a_tab_they_hold
    return if tab_permitted?(requested_tab)

    redirect_to workshop_configuration_path(tab: default_tab),
                alert: "You don't have permission to open that tab."
  end

  # An unnamed or unrecognised integration permits no field at all, so the
  # update is a no-op — and `project.update({})` returns true, which used to
  # toast "Integration settings saved" over a form that saved nothing.
  def save_integration(project)
    fields = INTEGRATION_FIELDS[params[:integration].to_s]
    unless fields
      flash[:alert] = "Unknown integration #{params[:integration].to_s.inspect} — nothing was saved."
      return
    end

    save_project_fields(project, fields, "Integration settings saved")
    # Same rule as ProjectCreator: a site AND a key are what make a project a
    # Jira project. This is the only screen that can supply the pair after the
    # fact, so without this a project created with "Set up later" could never
    # become one — nothing would ever sync it.
    if params[:integration].to_s == "jira" && !project.jira_connected? &&
       project.jira_site.present? && project.external_reference.present?
      project.update(external_type: "jira")
    end
    ProjectMcpConfig.write!(project) if project.workspace_dir.present?
    # Saving GitHub is what makes the repo reachable, so this is where its
    # checkout starts: a clone the first time, a pull after that. The job checks
    # the credentials itself; asking here just keeps a half-filled form from
    # queuing a job that would do nothing.
    if params[:integration].to_s == "github" && ProjectCredentials.new(project).github_configured?
      ProjectRepoCheckoutJob.perform_later(project.id)
    end
  end

  def save_project_fields(project, fields, notice)
    attrs = params.require(:project).permit(*fields, estimation_field_names: []).to_h.symbolize_keys
    SECRETS.each { |secret| attrs.delete(secret) if attrs[secret].blank? }

    names = Array(attrs[:estimation_field_names]).map { |n| n.to_s.strip }.reject(&:blank?)
    names.any? ? attrs[:estimation_field_names] = names : attrs.delete(:estimation_field_names)

    if project.update(attrs)
      flash[:clar_toast] = notice
    else
      flash[:alert] = project.errors.full_messages.to_sentence
    end
  end

  # require(:project) rather than dig: a request carrying no project key used to
  # write nil over the stored personas and report success.
  def save_briefing(project)
    personas = params.require(:project)[:briefing_personas].to_s.strip.presence

    if project.update(briefing_personas: personas)
      flash[:clar_toast] = "Briefing settings saved"
    else
      flash[:alert] = project.errors.full_messages.to_sentence
    end
  end

  def redirect_with(alert, tab)
    flash[:alert] = alert
    redirect_to workshop_configuration_path(tab: tab)
  end

  def load_ai_tab
    project = current_workshop_project
    @estimation_board_name = project&.name
    @estimation_field_names = project&.estimation_field_names ||
                              [ EstimationSettings::DEFAULT_ESTIMATION_FIELD_NAME ]
    @estimation_trigger = project&.estimation_trigger
    @pr_review_prompt = project&.pr_review_prompt.presence || PrReviewJob::DEFAULT_PROMPT
    @poll_minutes = project&.pr_poll_minutes || 7
  end

  # Briefing tab: the two inputs (per-project) that feed the briefing PO chat —
  # human-written personas + the auto-scanned plain-language feature summary.
  def load_briefing_tab
    @briefing_personas = current_workshop_project&.briefing_personas
    @features_summary = current_workshop_project&.features_summary
    @features_summary_updated_at = current_workshop_project&.features_summary_updated_at
  end

  def load_integrations_tab
    @discord_webhooks = current_workshop_project&.discord_webhooks&.order(:channel_name) || DiscordWebhook.none
    # "Connected" reflects the project's resolved Jira (per-project creds, with
    # ENV fallback), not just the global ENV domain.
    @jira_configured = current_workshop_project &&
                       ProjectCredentials.new(current_workshop_project).jira_configured?
  end

  # Per-project membership, with the switches that decide each person's
  # access on THIS project — permission_role_badge reads role_label off these,
  # which only a ProjectMembership (or ProjectAccess) can answer.
  def load_users_tab
    project = current_workshop_project
    # No project selected means nothing to list. The method in the tree guards
    # this today and the grid must keep doing so, or the tab 500s on a fresh
    # session before a project has been picked.
    unless project
      @members = []
      @addable_users = User.none
      return
    end

    rows = project.project_memberships.includes(:user).joins(:user).order("users.name")

    # A workspace admin holds every permission here whether or not anyone ever
    # added them to this project. Reading project_memberships alone would leave
    # the person with the most power over the project as the one name missing
    # from its access list, so append them as unsaved rows.
    admins = current_workspace.workspace_memberships.where(workspace_admin: true)
                              .includes(:user).map(&:user)
    missing = admins - rows.map(&:user)
    @members = rows.to_a + missing.map { |user| project.project_memberships.new(user: user) }

    # Which rows render locked, answered once here instead of by a
    # ProjectAccess per row: the grid is built from this very fact, and asking
    # again cost a workspace_memberships query for every person on screen.
    @admin_user_ids = admins.map(&:id)

    # People who already have an account in ANOTHER project of this workspace.
    # Not everyone in the workspace: an employee holding HR access and no
    # project was deliberately kept out of the Workshop, and a project
    # membership is exactly what would let them in. Administrators are left out
    # too — ProjectMembersController refuses to give them a row.
    @addable_users = User.joins(:project_memberships)
                         .where(project_memberships: { project_id: current_workspace.projects.select(:id) })
                         .where.not(id: @members.map(&:user_id))
                         .where.not(id: @admin_user_ids)
                         .distinct
                         .order(:name)
  end
end
