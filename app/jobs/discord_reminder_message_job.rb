class DiscordReminderMessageJob < ApplicationJob
  queue_as :default

  def perform(recipient_id)
    recipient = DiscordReminderRecipient.find_by(id: recipient_id, active: true)
    return unless recipient

    hours = format("%g", recipient.min_daily_hours)
    content = "<@#{recipient.discord_user_id}> you logged under #{hours}h on one " \
              "or more of the last 3 working days — please log your time 🙏"

    DiscordGroupClient.new.post(content)
  end
end
