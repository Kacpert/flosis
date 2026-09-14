class WorkspacesController < ApplicationController
  # This controller intentionally does NOT include WorkspaceScoped (it manages
  # workspaces, including for users who have none yet). A client account is
  # single-workspace and admin-managed, so clients must not create or switch
  # workspaces — bounce them to Jira Tasks.
  before_action :block_clients

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

  # A user is treated as a client if any of their memberships still carries the
  # legacy `client` role (raw value 3 — the enum is gone as of Task 9, and no
  # membership is created with this role any more). Client accounts have
  # exactly one membership in practice.
  def block_clients
    if current_user&.workspace_memberships&.exists?(role: 3)
      redirect_to jira_tasks_path, alert: "Clients can't manage workspaces."
    end
  end

  def workspace_params
    params.require(:workspace).permit(:name)
  end
end
