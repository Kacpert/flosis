# Plans (SCRUM-70): what Flosis sells an organization — a monthly price, which
# is its monthly limit, a margin added to every run's reported cost, and the
# models it includes (information for now: nothing is restricted by them).
# A plan can be assigned as it is created; Organizations assigns the rest.
class Hidmin::PlansController < Hidmin::BaseController
  before_action :set_plan, only: %i[edit update]

  def index
    @plans = AiPlan.includes(:ai_models, :workspaces).order(:monthly_price_usd, :name)
  end

  def new
    @plan = AiPlan.new(margin_percent: AiRun.default_margin_percent)
    load_form
  end

  def create
    @plan = AiPlan.new(plan_params)
    if @plan.save
      assign_if_asked
      redirect_to hidmin_plans_path, flash: { clar_toast: "Plan created" }
    else
      load_form
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_form
  end

  def update
    if @plan.update(plan_params)
      assign_if_asked
      redirect_to hidmin_plans_path, flash: { clar_toast: "Plan saved" }
    else
      load_form
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_plan
    @plan = AiPlan.find(params[:id])
  end

  def plan_params
    params.require(:ai_plan).permit(:name, :monthly_price_usd, :margin_percent, ai_model_ids: [])
  end

  def load_form
    AiModel.seed!
    @models = AiModel.order(:model_id)
    @default_model = AiModel.normalize_id(AiRun.where.not(model: nil).order(ran_at: :desc).pick(:model))
    @workspaces = Workspace.includes(:ai_plan).order(:name)
  end

  # "Assign it now": the plan's price becomes the organization's limit from
  # this moment; its runs so far keep the margin they were priced with. An
  # organization paying for its plan gets it with its next charge instead
  # (SCRUM-71, Billing::Plans.assign_by_staff!).
  def assign_if_asked
    workspace = Workspace.find_by(id: params[:assign_workspace_id])
    return unless workspace

    Billing::Plans.assign_by_staff!(workspace, @plan)
  end
end
