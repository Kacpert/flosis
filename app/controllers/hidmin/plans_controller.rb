# Plans (SCRUM-70): what Flosis sells an organization — a monthly price (its
# limit), a margin and the models it includes. Filled in by Task 13.
class Hidmin::PlansController < Hidmin::BaseController
  def index
    @plans = AiPlan.order(:monthly_price_usd)
  end

  def new
    @plan = AiPlan.new
  end

  def edit
    @plan = AiPlan.find(params[:id])
  end

  def create
    head :not_implemented
  end

  def update
    head :not_implemented
  end
end
