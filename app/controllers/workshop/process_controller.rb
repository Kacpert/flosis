# Process Optimization: three AI automations (PR reviews, estimate, alerts)
# that comment/propose but never decide for the team. This task builds the
# AI PR Reviews tab only; estimate/alerts render "coming later" placeholders
# (Tasks 6.3/6.4 fill them in).
class Workshop::ProcessController < Workshop::BaseController
  TABS = %w[pr estimate alerts].freeze

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "pr"

    if @tab == "pr"
      @pr_reviews = current_workspace.pr_reviews.order(reviewed_at: :desc).limit(20)
      today_reviews = current_workspace.pr_reviews.where("reviewed_at >= ?", Time.current.beginning_of_day)
      @reviewed_today_count = today_reviews.count
      @comments_count = today_reviews.where(outcome: "comments").count
      @looks_good_count = today_reviews.where(outcome: "looks_good").count
      @poll_minutes = [ 7, current_workspace.pr_poll_minutes ].max
    end
  end
end
