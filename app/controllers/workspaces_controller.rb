class WorkspacesController < ApplicationController
  # This controller intentionally does NOT include WorkspaceScoped (it manages
  # workspaces, including for users who have none yet). A client account is
  # admin-managed, so it must not create workspaces — bounce it to Jira Tasks.
  # Switching stays open to everyone: it only ever moves between workspaces the
  # person already belongs to, and Flosis staff may put a client into several.
  before_action :block_restricted_accounts, except: :switch

  def new
    @workspace = Workspace.new
  end

  def create
    @workspace = Workspace.new(workspace_params)

    if @workspace.save
      @workspace.workspace_memberships.create!(user: current_user, workspace_admin: true)
      session[:workspace_id] = @workspace.id
      redirect_to root_path, notice: "Workspace created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # A switch may name the product to land in, so switching from the Workshop
  # stays in the Workshop. It is only a preference: current_product drops it
  # where the person has no access to that product.
  def switch
    workspace = current_user.workspaces.find(params[:id])
    session[:workspace_id] = workspace.id
    session[:product] = params[:product] if params[:product].in?(WorkspaceScoped::PRODUCTS)
    redirect_to root_path, notice: "Switched to #{workspace.name}."
  end

  private

  # A restricted account — no HR access and no workspace privilege anywhere —
  # is managed by an administrator, so it must not create workspaces. Replaces
  # the old check on the `client` role, whose column this release drops.
  def block_restricted_accounts
    memberships = current_user&.workspace_memberships
    return if memberships.blank?
    return if memberships.where(workspace_admin: true).exists?
    return if memberships.joins(:workspace).where(time_hr_access: true, workspaces: { hr_access: true }).exists?

    redirect_to jira_tasks_path, alert: "Your account is managed by an administrator."
  end

  def workspace_params
    params.require(:workspace).permit(:name)
  end
end
