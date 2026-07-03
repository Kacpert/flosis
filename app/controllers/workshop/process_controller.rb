# Process Optimization: three AI automations (PR reviews, estimate, alerts)
# that comment/propose but never decide for the team.
class Workshop::ProcessController < Workshop::BaseController
  TABS = %w[pr estimate alerts].freeze

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "pr"

    case @tab
    when "pr"
      @pr_reviews = current_workspace.pr_reviews.order(reviewed_at: :desc).limit(20)
      today_reviews = current_workspace.pr_reviews.where("reviewed_at >= ?", Time.current.beginning_of_day)
      @reviewed_today_count = today_reviews.count
      @comments_count = today_reviews.where(outcome: "comments").count
      @looks_good_count = today_reviews.where(outcome: "looks_good").count
      @poll_minutes = [ 7, current_workspace.pr_poll_minutes ].max
    when "estimate"
      load_estimate_tab
    when "alerts"
      load_alerts_tab
    end
  end

  private

  def load_alerts_tab
    @alert_rules = current_workshop_project ? current_workshop_project.alert_rules.order(created_at: :desc) : AlertRule.none
    @discord_webhooks = current_workspace.discord_webhooks.order(:channel_name)
  end

  def load_estimate_tab
    @estimation_board_name = current_workshop_project&.name
    @estimation_trigger_label = current_workspace.estimation_trigger_label
    @estimation_field_names = current_workspace.estimation_field_names
    @estimated_tasks = current_workshop_project ? current_workshop_project.tasks
      .where.not(ai_estimated_at: nil)
      .order(ai_estimated_at: :desc)
      .limit(20) : Task.none
  end
end
