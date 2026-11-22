# Consumption (SCRUM-70): every AI run the organization made, priced on its
# plan, for a calendar month or all time — totals against the plan's limit, by
# area, by project, and the runs themselves. Organization administrators only
# (anyone else gets a 404); it is the organization's money, not a project's,
# and it ignores both cost-display switches. Prices only: cost and margin are
# on Flosis's own /hidmin.
class Workshop::ConsumptionController < Workshop::BaseController
  skip_before_action :require_current_project!, :require_project_member!
  before_action :require_workspace_admin!

  PAGE = 50

  def show
    @costs = AiCosts.new(current_workspace)
    @months = @costs.months
    @all_time = params[:view] == "all"
    @month = picked_month || @months.first
    @summary = @all_time ? @costs.all_time : @costs.month(@month)
    @offset = params[:offset].to_i.clamp(0, nil)
    @runs = @costs.runs(@month, offset: @offset, limit: PAGE) unless @all_time

    render "workshop/consumption/more", layout: false if @offset.positive? && turbo_frame_request?
  end

  private

  def require_workspace_admin!
    head :not_found unless workspace_admin?
  end

  def picked_month
    Date.strptime(params[:month].to_s, "%Y-%m")
  rescue Date::Error
    nil
  end
end
