class WorkspaceSettingsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!

  def show
    @workspace = current_workspace
    @discord_recipients = current_workspace.discord_reminder_recipients.includes(:user).order("users.name")
    @workspace_users = current_workspace.users.order(:name)
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
    permitted = params.require(:workspace).permit(:clients_enabled, :discord_channel_id, :discord_user_token)
    # Blank token field means "leave unchanged" (the field is never pre-filled),
    # so don't wipe a stored token when the admin saves other settings.
    permitted.delete(:discord_user_token) if permitted[:discord_user_token].blank?
    permitted
  end
end
