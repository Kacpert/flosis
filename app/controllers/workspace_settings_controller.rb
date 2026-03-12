class WorkspaceSettingsController < ApplicationController
  include WorkspaceScoped

  def show
  end

  def update
    ws_params = params.require(:workspace).permit(:name, :default_currency, :week_start, :time_format)

    # Convert dollars to cents for hourly rate
    if params[:workspace][:default_hourly_rate_dollars].present?
      ws_params[:default_hourly_rate_cents] = (params[:workspace][:default_hourly_rate_dollars].to_f * 100).round
    end

    if current_workspace.update(ws_params)
      redirect_to workspace_settings_path, notice: "Workspace settings updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def current_workspace
    Current.workspace
  end
end
