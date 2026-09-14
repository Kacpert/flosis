# Configuration: per-project credentials, AI behaviour and access. Each tab
# costs a permission (see TAB_PERMISSIONS); the page opens for anyone holding
# either of the two the tabs use, and a tab you lack renders locked instead of
# missing.
class Workshop::ConfigurationController < Workshop::BaseController
  TABS = %w[integrations ai briefing users].freeze

  # What each tab costs. Briefing is the one a Product Owner holds, which is
  # why this is a per-tab map and not a single gate on the page.
  TAB_PERMISSIONS = {
    "integrations" => :configuration,
    "ai" => :configuration,
    "briefing" => :briefing_config,
    "users" => :configuration
  }.freeze

  before_action :require_configuration_access!
  before_action :redirect_to_a_tab_they_hold, only: :show

  def show
    @tab = requested_tab
    load_ai_tab if @tab == "ai"
    load_briefing_tab if @tab == "briefing"
    load_integrations_tab if @tab == "integrations"
    load_users_tab if @tab == "users"
  end

  def update
    tab = TABS.include?(params[:tab]) ? params[:tab] : "ai"
    return head :forbidden unless tab_permitted?(tab)

    case tab
    when "ai"
      update_ai_settings
    when "briefing"
      update_briefing_settings
    when "integrations"
      update_integrations_settings
    end

    redirect_to workshop_configuration_path(tab: tab)
  end

  # Duplicated from WorkspaceSettingsController#test_github (HR's Workspace
  # Settings) rather than reused — the HR-BOUNDARY constraint for this task
  # forbids touching HR's controller/route. Same 5-line body, different
  # redirect target and flash key (clar_toast vs notice).
  def test_github
    result = GithubClient.for(current_workspace).health_check
    current_workspace.update_columns(
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
    client = JiraClient.new
    current_workspace.update!(
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

  def tab_permitted?(tab)
    can?(TAB_PERMISSIONS.fetch(tab, :configuration))
  end
  helper_method :tab_permitted?

  def redirect_to_a_tab_they_hold
    return if tab_permitted?(requested_tab)

    redirect_to workshop_configuration_path(tab: default_tab),
                alert: "You don't have permission to open that tab."
  end

  def update_integrations_settings
    return save_jira_integration if params[:integration] == "jira"

    save_workspace_integration # existing github_repo/token/toggles path (legacy)
  end

  # Per-project Jira credentials (Task 9). Secrets are encrypted on the project;
  # a blank token preserves the existing one. Regenerates the project's .mcp.json
  # so automations pick up the new creds immediately. GitHub creds stay on the
  # workspace (legacy PrReviewJob path); ProjectCredentials falls back to the
  # workspace for github, so per-project automations still get a working token.
  def save_jira_integration
    project = current_workshop_project
    return flash[:alert] = "No project selected." unless project
    attrs = params.require(:project).permit(:jira_site, :jira_email, :jira_api_token)
    attrs.delete(:jira_api_token) if attrs[:jira_api_token].blank?
    if project.update(attrs)
      ProjectMcpConfig.write!(project) if project.workspace_dir.present?
      flash[:clar_toast] = "Jira settings saved"
    else
      flash[:alert] = project.errors.full_messages.to_sentence
    end
  end

  # Legacy workspace-level integration save (unchanged behavior) — GitHub repo/
  # token + PR-review toggle live on the workspace.
  def save_workspace_integration
    attrs = integrations_settings_params
    attrs.delete(:github_token) if attrs[:github_token].blank?
    if current_workspace.update(attrs)
      flash[:clar_toast] = "Integration settings saved"
    else
      flash[:alert] = current_workspace.errors.full_messages.to_sentence
    end
  end

  def integrations_settings_params
    params.require(:workspace).permit(
      :github_repo, :github_token, :pr_review_enabled, :figma_read_enabled
    )
  end

  def load_ai_tab
    @estimation_board_name = current_workshop_project&.name
    @estimation_field_names = current_workspace.estimation_field_names
    @estimation_trigger = current_workspace.estimation_trigger
    @pr_review_prompt = current_workspace.pr_review_prompt.presence || PrReviewJob::DEFAULT_PROMPT
    @poll_minutes = current_workspace.pr_poll_minutes
  end

  # Briefing tab: the two inputs (per-project) that feed the briefing PO chat —
  # human-written personas + the auto-scanned plain-language feature summary.
  def load_briefing_tab
    @briefing_personas = current_workshop_project&.briefing_personas
    @features_summary = current_workshop_project&.features_summary
    @features_summary_updated_at = current_workshop_project&.features_summary_updated_at
  end

  def load_integrations_tab
    @discord_webhooks = current_workspace.discord_webhooks.order(:channel_name)
    # "Connected" reflects the project's resolved Jira (per-project creds, with
    # ENV fallback), not just the global ENV domain.
    @jira_configured = current_workshop_project &&
                       ProjectCredentials.new(current_workshop_project).jira_configured?
  end

  # Per-project membership, with the switches that decide each person's
  # access on THIS project — permission_role_badge reads role_label off these,
  # which only a ProjectMembership (or ProjectAccess) can answer.
  def load_users_tab
    @members = if current_workshop_project
      current_workshop_project.project_memberships.includes(:user).joins(:user).order("users.name")
    else
      ProjectMembership.none
    end
  end

  def update_ai_settings
    attrs = ai_settings_params

    field_names = Array(attrs[:estimation_field_names]).map(&:to_s).map(&:strip).reject(&:blank?)
    if field_names.any?
      attrs[:estimation_field_names] = field_names
    else
      attrs.delete(:estimation_field_names)
    end

    if current_workspace.update(attrs)
      flash[:clar_toast] = "AI settings saved"
    else
      flash[:alert] = current_workspace.errors.full_messages.to_sentence
    end
  end

  # briefing_personas lives on the project, not the workspace.
  def update_briefing_settings
    personas = params.dig(:workspace, :briefing_personas)
    if current_workshop_project&.update(briefing_personas: personas.to_s.strip.presence)
      flash[:clar_toast] = "Briefing settings saved"
    else
      flash[:alert] = "No project selected."
    end
  end

  def ai_settings_params
    params.require(:workspace).permit(
      :pr_review_prompt,
      :pr_poll_minutes,
      :estimation_trigger,
      :estimation_status_trigger,
      :figma_read_enabled,
      estimation_field_names: []
    )
  end
end
