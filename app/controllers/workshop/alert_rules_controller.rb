# AI Alerts (Task 6.4): scoped prompts that run on a schedule and notify a
# Discord channel only when their condition is met. Rules are scoped to
# current_workshop_project (find always via that association — a crafted
# cross-project id 404s), same convention as DesignRequestsController.
class Workshop::AlertRulesController < Workshop::BaseController
  before_action :set_alert_rule, only: [ :destroy, :history ]

  def create
    rule = current_workshop_project.alert_rules.new(create_params)
    rule.workspace = current_workspace

    if rule.save
      flash[:clar_toast] = %(Alert rule created · "#{rule.name}")
    else
      flash[:alert] = rule.errors.full_messages.to_sentence
    end

    redirect_to workshop_process_path(tab: "alerts")
  end

  def destroy
    @alert_rule.destroy
    flash[:clar_toast] = %(Alert rule removed · "#{@alert_rule.name}")
    redirect_to workshop_process_path(tab: "alerts"), status: :see_other
  end

  # Rendered inside a turbo frame from the rules list card (history modal).
  def history
    @runs = @alert_rule.alert_runs.newest_first.limit(30)
    @fired_count = @runs.count(&:fired)

    render partial: "workshop/process/history_modal", layout: false
  end

  private

  def set_alert_rule
    @alert_rule = current_workshop_project.alert_rules.find(params[:id])
  end

  def create_params
    params.require(:alert_rule).permit(:name, :prompt, :frequency, :run_at_time, :discord_webhook_id)
  end
end
