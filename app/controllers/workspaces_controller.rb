class WorkspacesController < ApplicationController
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

  def workspace_params
    params.require(:workspace).permit(:name)
  end
end
