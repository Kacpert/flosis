# Configuration (Task 9.1): admin-only per-project credentials, AI behaviour
# and access. Gated by require_admin! — Product Owners (employees with
# workshop_access) must never reach this page (D5-adjacent access rule).
#
# This task builds the page shell + the AI tab in full. Integrations (9.2) and
# Users (9.3) render as placeholders for now.
class Workshop::ConfigurationController < Workshop::BaseController
  TABS = %w[integrations ai users].freeze

  before_action :require_admin!

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "ai"
    load_ai_tab if @tab == "ai"
    load_integrations_tab if @tab == "integrations"
  end

  def update
    tab = TABS.include?(params[:tab]) ? params[:tab] : "ai"

    case tab
    when "ai"
      update_ai_settings
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

  private

  def update_integrations_settings
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

  def load_integrations_tab
    @discord_webhooks = current_workspace.discord_webhooks.order(:channel_name)
    @jira_configured = ENV["JIRA_DOMAIN"].present?
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
