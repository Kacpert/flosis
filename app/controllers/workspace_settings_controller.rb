class WorkspaceSettingsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!

  def show
    @workspace = current_workspace
  end

  def update
    if current_workspace.update(workspace_settings_params)
      redirect_to workspace_settings_path, notice: "Workspace settings updated."
    else
      @workspace = current_workspace
      render :show, status: :unprocessable_entity
    end
  end

  private

  def workspace_settings_params
    params.require(:workspace).permit(:clients_enabled)
  end
end
