# Organizations are workspaces. A new one is saved together with its first
# administrator, or not at all: an organization nobody can run would need a
# console session to fix.
class Hidmin::WorkspacesController < Hidmin::BaseController
  before_action :set_workspace, only: %i[show update assign_plan]

  # SCRUM-70: the organizations as Flosis bills them this month — plan,
  # margin, cost, price, the limit and unknown-cost runs not yet looked at.
  def index
    @workspaces = Workspace.includes(:ai_plan).order(:name)
    @member_counts = WorkspaceMembership.group(:workspace_id).count
    @project_counts = Project.active.group(:workspace_id).count
    @own_key_counts = Project.active.where.not(anthropic_api_key: [ nil, "" ]).group(:workspace_id).count
    @billing = AiBilling.organizations
    @plans = AiPlan.order(:monthly_price_usd, :name)
  end

  def show
    load_members
    @billing = AiBilling.new(@workspace)
  end

  def new
    @workspace = Workspace.new(workshop_enabled: true)
    @invite = WorkspaceInvite.new(@workspace, name: "", email_address: "")
  end

  def create
    @workspace = Workspace.new(workspace_params)
    @invite = WorkspaceInvite.new(@workspace, **admin_params, workspace_admin: true)

    if [ @workspace.valid?, @invite.valid? ].all?
      Workspace.transaction do
        @workspace.save!
        @invite.save!
      end
      @invite.deliver_later
      redirect_to hidmin_workspace_path(@workspace), notice: "#{@workspace.name} created. #{@invite.user.name} is its administrator and has been emailed."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @workspace.update(workspace_params)
      redirect_to hidmin_workspace_path(@workspace), notice: "Saved."
    else
      load_members
      render :show, status: :unprocessable_entity
    end
  end

  # SCRUM-70: an organization's plan. Its price becomes the monthly limit from
  # now on (this month's included); runs so far keep the margin they had.
  #
  # SCRUM-71: an organization that pays for its plan keeps the month it paid
  # for; the plan staff assign starts with its next charge, on the 1st.
  def assign_plan
    plan = AiPlan.find(params[:ai_plan_id])
    account = @workspace.billing_account
    if account&.plan_running?
      account.update!(pending_ai_plan: plan == @workspace.ai_plan ? nil : plan)
      return redirect_back_or_to(hidmin_workspaces_path, flash: { clar_toast: "#{plan.name} starts on #{Date.current.next_month.beginning_of_month.strftime('%-d %b')}, with the next charge" })
    end

    @workspace.update!(ai_plan: plan, ai_plan_assigned_at: Time.current)
    @workspace.billing.update!(plan_state: "pending") if @workspace.billing.plan_state.in?(%w[none ended])
    AiMonthLimit.refresh_current!(@workspace)
    redirect_back_or_to hidmin_workspaces_path, flash: { clar_toast: "Plan assigned" }
  end

  private

  def set_workspace
    @workspace = Workspace.find(params[:id])
  end

  def load_members
    @memberships = @workspace.workspace_memberships.includes(:user).order("users.name").references(:user)
    @projects = @workspace.projects.order(:archived, :name)
    @billing ||= AiBilling.new(@workspace)
    @new_member = WorkspaceInvite.new(@workspace, name: "", email_address: "")
  end

  def workspace_params
    params.require(:workspace).permit(:name, :workshop_enabled, :hr_access, :clients_enabled)
  end

  def admin_params
    admin = params.fetch(:admin, {}).permit(:name, :email_address, :time_hr_access)
    { name: admin[:name], email_address: admin[:email_address], time_hr_access: admin[:time_hr_access] == "1" }
  end
end
