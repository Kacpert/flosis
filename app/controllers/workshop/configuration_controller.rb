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
  end

  def update
    tab = TABS.include?(params[:tab]) ? params[:tab] : "ai"

    case tab
    when "ai"
      update_ai_settings
    end

    redirect_to workshop_configuration_path(tab: tab)
  end

  private

  def load_ai_tab
    @estimation_board_name = current_workshop_project&.name
    @estimation_field_names = current_workspace.estimation_field_names
    @estimation_trigger = current_workspace.estimation_trigger
    @pr_review_prompt = current_workspace.pr_review_prompt.presence || PrReviewJob::DEFAULT_PROMPT
    @poll_minutes = current_workspace.pr_poll_minutes
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
