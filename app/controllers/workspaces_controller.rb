class WorkspacesController < ApplicationController
  # This controller intentionally does NOT include WorkspaceScoped (it manages
  # workspaces, including for users who have none yet), so the client redirect
  # there doesn't apply. A client account is single-workspace and admin-managed,
  # so clients must not create or switch workspaces — bounce them to Jira Tasks.
  before_action :block_clients

  def new
    @workspace = Workspace.new
  end

  def create
    @workspace = Workspace.new(workspace_params)

    if @workspace.save
      @workspace.workspace_memberships.create!(user: current_user, role: :owner)
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

  # A user is treated as a client if any of their memberships is a client role.
  # (Client accounts have exactly one membership in practice.)
  def block_clients
    if current_user&.workspace_memberships&.exists?(role: :client)
      redirect_to jira_tasks_path, alert: "Clients can't manage workspaces."
    end
  end

  def workspace_params
    params.require(:workspace).permit(:name)
  end
end
