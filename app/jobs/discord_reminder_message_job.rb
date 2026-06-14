class DiscordReminderMessageJob < ApplicationJob
  queue_as :default

  # variant: "morning" (gentle reminder), "afternoon" (more urgent reminder), or
  # "praise" (motivating shout-out for someone who's logging well). Reminders
  # never disclose hours.
  MESSAGES = {
    "morning" => [
      "<@%<id>s> looks like there are some missing hours in the last 3 working days — could you log your time? 🙏",
      "<@%<id>s> good morning! A few hours seem to be missing from the last 3 working days — mind logging them? ☕️",
      "<@%<id>s> friendly nudge: some time from the last 3 working days isn't logged yet 🙂",
      "<@%<id>s> morning! Could you fill in the missing hours from the last 3 working days when you get a sec? 🙏"
    ],
    "afternoon" => [
      "<@%<id>s> hey, there are still missing hours in the last 3 working days — please log your time 🙏",
      "<@%<id>s> heads up — those missing hours from the last 3 working days are still open. Could you log them? ⏰",
      "<@%<id>s> still seeing gaps in the last 3 working days — please get your time logged today 🙏",
      "<@%<id>s> end-of-day reminder: some hours from the last 3 working days are still missing ⏳"
    ],
    "praise" => [
      "<@%<id>s> your time tracking looks great these days — keep up the awesome work! 🌟",
      "<@%<id>s> nice one — all your hours are logged and looking sharp. Keep it up! 💪",
      "<@%<id>s> spotless time tracking lately 👏 thanks for staying on top of it!",
      "<@%<id>s> kudos — your logging has been right on point. Keep crushing it! 🚀"
    ]
  }.freeze

  REMINDER_VARIANTS = %w[morning afternoon].freeze

  def perform(recipient_id, variant = "morning")
    recipient = DiscordReminderRecipient.find_by(id: recipient_id, active: true)
    return unless recipient

    templates = MESSAGES[variant] || MESSAGES["morning"]
    content = format(templates.sample, id: recipient.discord_user_id)

    # Reminders (not praise) are logged and carry a "you've been pinged N times"
    # tally so people can see how often they're being reminded.
    if REMINDER_VARIANTS.include?(variant)
      recipient.discord_reminder_pings.create!(sent_at: Time.current)
      content += " #{reminder_count_suffix(recipient)}"
    end

    DiscordGroupClient.for(recipient.workspace).post(content)
  end

  private

  def reminder_count_suffix(recipient)
    week = recipient.discord_reminder_pings.since(Time.current.beginning_of_week).count
    month = recipient.discord_reminder_pings.since(Time.current.beginning_of_month).count
    "(reminder ##{week} this week, ##{month} this month)"
  end
end
