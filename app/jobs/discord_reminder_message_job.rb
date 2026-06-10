class DiscordReminderMessageJob < ApplicationJob
  queue_as :default

  # variant: "morning" (gentle) or "afternoon" (more urgent). Never discloses hours.
  MESSAGES = {
    "morning" => "<@%<id>s> looks like there are some missing hours in the last 3 working days — could you log your time? 🙏",
    "afternoon" => "<@%<id>s> hey, there are still missing hours in the last 3 working days — please log your time 🙏"
  }.freeze

  def perform(recipient_id, variant = "morning")
    recipient = DiscordReminderRecipient.find_by(id: recipient_id, active: true)
    return unless recipient

    template = MESSAGES[variant] || MESSAGES["morning"]
    content = format(template, id: recipient.discord_user_id)

    DiscordGroupClient.for(recipient.workspace).post(content)
  end
end
