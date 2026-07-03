# Configuration -> Integrations -> Discord (Task 9.2): manages the webhooks
# AI Alerts (Task 6.4) post to. Admin-gated (like the rest of Configuration).
# The Discord reminder group-DM config (HR's discord_reminder_recipients)
# is untouched — a completely separate feature living in HR Workspace Settings.
class Workshop::DiscordWebhooksController < Workshop::BaseController
  before_action :require_admin!
  before_action :set_discord_webhook, only: [ :destroy ]

  def create
    webhook = current_workspace.discord_webhooks.new(create_params)

    if webhook.save
      flash[:clar_toast] = %(Webhook added · "#{webhook.channel_name}")
    else
      flash[:alert] = webhook.errors.full_messages.to_sentence
    end

    redirect_to workshop_configuration_path(tab: "integrations")
  end

  # AlertRule#discord_webhook has_many :alert_rules, dependent: :restrict_with_error
  # (Task 6.4) — destroy returns false and adds a base error when rules still
  # reference this webhook. Surface that as the toast instead of a silent no-op.
  def destroy
    rule_count = @discord_webhook.alert_rules.count

    if @discord_webhook.destroy
      flash[:clar_toast] = %(Webhook removed · "#{@discord_webhook.channel_name}")
    else
      flash[:clar_toast] = "Webhook is used by #{rule_count} alert rules"
    end

    redirect_to workshop_configuration_path(tab: "integrations"), status: :see_other
  end

  private

  # Scope-safe: a crafted id from another workspace 404s rather than leaking
  # existence or letting an admin delete another workspace's webhook.
  def set_discord_webhook
    @discord_webhook = current_workspace.discord_webhooks.find(params[:id])
  end

  def create_params
    params.require(:discord_webhook).permit(:channel_name, :url)
  end
end
