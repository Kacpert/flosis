# AI Alerts (Task 6.4): scoped prompts that run on a schedule and notify a
# Discord channel only when their condition is met. Rules are scoped to
# current_workshop_project (find always via that association — a crafted
# cross-project id 404s), same convention as DesignRequestsController.
class Workshop::AlertRulesController < Workshop::BaseController
  before_action :set_alert_rule,
                only: [ :update, :destroy, :history, :memory, :clear_memory, :clear_ai_issues, :toggle_active ]

  def create
    rule = current_workshop_project.alert_rules.new(create_params.except(:discord_webhook_id))
    rule.workspace = current_workspace
    # Scope the webhook to THIS workspace — a crafted discord_webhook_id from
    # another workspace must not attach (it would post alerts into that
    # workspace's Discord channel). Only attach it when notifications are on.
    if rule.notify_enabled?
      rule.discord_webhook = current_workspace.discord_webhooks.find_by(id: create_params[:discord_webhook_id])
    end

    if rule.save
      flash[:clar_toast] = %(Alert rule created · "#{rule.name}")
    else
      flash[:alert] = rule.errors.full_messages.to_sentence
    end

    redirect_to workshop_process_path(tab: "alerts")
  end

  def update
    attrs = create_params.except(:discord_webhook_id)
    # When notifications are turned OFF, drop the channel entirely. When ON,
    # (re)assign a workspace-scoped webhook if one was chosen.
    if create_params[:notify_enabled] == "0"
      attrs = attrs.merge(discord_webhook: nil)
    elsif create_params[:discord_webhook_id].present?
      wh = current_workspace.discord_webhooks.find_by(id: create_params[:discord_webhook_id])
      attrs = attrs.merge(discord_webhook: wh) if wh
    end

    if @alert_rule.update(attrs)
      flash[:clar_toast] = %(Alert rule updated · "#{@alert_rule.name}")
    else
      flash[:alert] = @alert_rule.errors.full_messages.to_sentence
    end

    redirect_to workshop_process_path(tab: "alerts")
  end

  def destroy
    @alert_rule.destroy
    flash[:clar_toast] = %(Alert rule removed · "#{@alert_rule.name}")
    redirect_to workshop_process_path(tab: "alerts"), status: :see_other
  end

  # Pause / resume an automation without deleting it. AlertRulesDispatchJob only
  # enqueues runs for AlertRule.active, so flipping this off stops the rule at
  # the next dispatch while keeping its prompt, schedule, memory and history.
  def toggle_active
    @alert_rule.update_column(:active, !@alert_rule.active?)
    flash[:clar_toast] = %(Automation #{@alert_rule.active? ? 'resumed' : 'paused'} · "#{@alert_rule.name}")
    # 303 so Turbo re-issues the follow-up as a GET (same contract as #destroy).
    redirect_to workshop_process_path(tab: "alerts"), status: :see_other
  end

  # Persist the order the operator dragged the cards into. Takes the full list of
  # ids; anything not in this project is ignored rather than trusted, so a
  # crafted payload can't renumber another project's rules.
  def reorder
    ids = Array(params[:ids]).map(&:to_i)
    rules = current_workshop_project.alert_rules.where(id: ids).index_by(&:id)

    AlertRule.transaction do
      ids.each_with_index do |id, index|
        rules[id]&.update_column(:position, index + 1)
      end
    end

    head :no_content
  end

  # Rendered inside a turbo frame from the rules list card (history modal).
  def history
    @runs = @alert_rule.alert_runs.newest_first.limit(30)
    @fired_count = @runs.count(&:fired)

    render partial: "workshop/process/history_modal", layout: false
  end

  # Read-only view of the automation's AI-managed memory + reported issues
  # (turbo-frame content for the memory modal). Not editable — debugging only.
  def memory
    render partial: "workshop/process/memory_modal", locals: { rule: @alert_rule }, layout: false
  end

  # Wipe the memory (and reported issues) so the automation rebuilds from scratch.
  def clear_memory
    @alert_rule.clear_memory!
    @alert_rule.clear_ai_issues!
    flash[:clar_toast] = %(Memory cleared · "#{@alert_rule.name}")
    redirect_to workshop_process_path(tab: "alerts")
  end

  # Dismiss the reported problems WITHOUT touching the memory. The report is the
  # AI's last word on what blocked it, and it only changes when the automation
  # next runs — so a problem you have already fixed keeps the card's Memory
  # button red for hours, with clearing the memory (and losing everything the
  # automation learned) as the only way to silence it.
  def clear_ai_issues
    @alert_rule.clear_ai_issues!
    flash[:clar_toast] = %(Reported issues cleared · "#{@alert_rule.name}")
    redirect_to workshop_process_path(tab: "alerts")
  end

  private

  def set_alert_rule
    @alert_rule = current_workshop_project.alert_rules.find(params[:id])
  end

  def create_params
    params.require(:alert_rule).permit(
      :name, :prompt, :run_at_time, :discord_webhook_id, :notify_enabled,
      # Schedule builder (replaces the old :frequency select — AlertRule keeps
      # the legacy frequency column in sync itself).
      :schedule_mode, :schedule_days, :interval_hours,
      :window_enabled, :window_from, :window_to
    )
  end
end
