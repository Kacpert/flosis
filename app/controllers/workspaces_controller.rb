class WorkspacesController < ApplicationController
  # This controller intentionally does NOT include WorkspaceScoped (it manages
  # workspaces, including for users who have none yet). A client account is
  # single-workspace and admin-managed, so clients must not create or switch
  # workspaces — bounce them to Jira Tasks.
  before_action :block_restricted_accounts

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

  def switch
    workspace = current_user.workspaces.find(params[:id])
    session[:workspace_id] = workspace.id
    redirect_to root_path, notice: "Switched to #{workspace.name}."
  end

  private

  # A restricted account — no HR access and no workspace privilege anywhere —
  # is managed by an administrator and belongs to one workspace, so it must not
  # create or switch workspaces. Replaces the old check on the `client` role,
  # whose column this release drops.
  def block_restricted_accounts
    memberships = current_user&.workspace_memberships
    return if memberships.blank?
    return if memberships.where(workspace_admin: true).exists?
    return if memberships.where(time_hr_access: true).exists?

    redirect_to jira_tasks_path, alert: "Your account is managed by an administrator."
  end

  def workspace_params
    params.require(:workspace).permit(:name)
  end
end
