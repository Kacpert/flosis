# SCRUM-71: when an organization's AI is paused (limit reached with no top-up
# left, or a payment unpaid), what would start an AI run says so instead of
# starting it. ClaudeCliService refuses the run anyway (PausedError); this is
# the plain answer before any side effect: no job queued, no message saved.
# An organization administrator is sent to Billing, anyone else to an admin.
module AiPauseGuard
  extend ActiveSupport::Concern

  included do
    helper_method :ai_allowance, :ai_paused?, :ai_paused_message, :ai_paused_who, :ai_paused_placeholder
  end

  private

  def ai_allowance
    return @ai_allowance if defined?(@ai_allowance)

    workspace = respond_to?(:current_workspace, true) ? current_workspace : nil
    @ai_allowance = workspace && Billing::Allowance.for(workspace)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { guard: "AiPauseGuard#ai_allowance" })
    @ai_allowance = nil
  end

  # Designs runs on a project's own Anthropic key, and those never pause.
  def ai_paused?(project: nil, designs: false)
    return false if designs && project&.anthropic_api_key.present?

    ai_allowance&.paused? || false
  end

  def ai_paused_placeholder
    Billing::Copy.paused_short(ai_allowance&.reason)
  end

  def ai_paused_who
    workspace_admin? ? "admin" : "member"
  end

  def ai_paused_message
    Billing::Copy.paused(ai_allowance&.reason, admin: ai_paused_who == "admin")
  end

  # A before_action for buttons that only queue an AI job.
  def refuse_when_ai_paused
    return unless ai_paused?

    flash[:alert] = ai_paused_message
    redirect_back(fallback_location: workshop_landing_path, status: :see_other)
  end

  # The same for Designs, where a project's own key keeps AI on.
  def refuse_designs_when_ai_paused
    return unless ai_paused?(project: current_workshop_project, designs: true)

    flash[:alert] = ai_paused_message
    redirect_back(fallback_location: workshop_landing_path, status: :see_other)
  end
end
