class DiscordReminderRecipientsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :set_recipient, only: %i[update destroy]

  def create
    recipient = current_workspace.discord_reminder_recipients.build(recipient_params)
    if recipient.save
      redirect_to workspace_settings_path, notice: "Discord recipient added."
    else
      redirect_to workspace_settings_path, alert: recipient.errors.full_messages.to_sentence
    end
  end

  def update
    if @recipient.update(recipient_params)
      redirect_to workspace_settings_path, notice: "Discord recipient updated."
    else
      redirect_to workspace_settings_path, alert: @recipient.errors.full_messages.to_sentence
    end
  end

  def destroy
    @recipient.destroy
    redirect_to workspace_settings_path, notice: "Discord recipient removed.", status: :see_other
  end

  private

  def set_recipient
    @recipient = current_workspace.discord_reminder_recipients.find(params[:id])
  end

  def recipient_params
    params.require(:discord_reminder_recipient).permit(:user_id, :discord_user_id, :min_daily_hours, :active)
  end
end
