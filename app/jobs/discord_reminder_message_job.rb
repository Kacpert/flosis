class DiscordReminderMessageJob < ApplicationJob
  queue_as :default

  # variant: "morning" (gentle reminder), "afternoon" (more urgent reminder), or
  # "praise" (motivating shout-out for someone who's logging well). Reminders
  # never disclose hours.
  MESSAGES = {
    "morning" => [ "<@%<id>s> looks like there are some missing hours in the last 3 working days — could you log your time? 🙏" ],
    "afternoon" => [ "<@%<id>s> hey, there are still missing hours in the last 3 working days — please log your time 🙏" ],
    "praise" => [
      "<@%<id>s> your time tracking looks great these days — keep up the awesome work! 🌟",
      "<@%<id>s> nice one — all your hours are logged and looking sharp. Keep it up! 💪",
      "<@%<id>s> spotless time tracking lately 👏 thanks for staying on top of it!",
      "<@%<id>s> kudos — your logging has been right on point. Keep crushing it! 🚀"
    ]
  }.freeze

  def perform(recipient_id, variant = "morning")
    recipient = DiscordReminderRecipient.find_by(id: recipient_id, active: true)
    return unless recipient

    templates = MESSAGES[variant] || MESSAGES["morning"]
    content = format(templates.sample, id: recipient.discord_user_id)

    DiscordGroupClient.for(recipient.workspace).post(content)
  end
end
