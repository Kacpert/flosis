class DiscordReminderJob < ApplicationJob
  queue_as :default

  WORKING_DAYS_WINDOW = 3
  # Each flagged person's message is sent at a random offset within this window
  # after the job runs, so the account behaves like a human rather than a bot
  # firing a burst at a fixed time.
  SPREAD = 120 # minutes

  # variant: "morning" (gentle wording) or "afternoon" (more urgent). Both spread
  # randomly over SPREAD minutes. The message job re-checks each recipient at
  # send time, so anyone who logs their hours during the spread is not pinged.
  def perform(variant = "morning")
    # Each workspace stores its own Discord token/channel; only act on configured ones.
    Workspace.where.not(discord_user_token: nil).where.not(discord_channel_id: nil).find_each do |workspace|
      next unless DiscordGroupClient.for(workspace).configured?

      workspace.discord_reminder_recipients.active.includes(:user).find_each do |recipient|
        if recipient.under_threshold_now?
          DiscordReminderMessageJob.set(wait: random_delay).perform_later(recipient.id, variant)
        elsif variant == "morning" && praise?
          # A doing-well user occasionally (~25%) gets a motivating shout-out,
          # only in the morning run, rolled independently per user.
          DiscordReminderMessageJob.set(wait: random_delay).perform_later(recipient.id, "praise")
        end
      end
    end
  end

  private

  # A random delay in [0, SPREAD] minutes so messages are spread out, not bursty.
  def random_delay
    rand(0..(SPREAD * 60)).seconds
  end

  # ~25% chance, rolled independently per good user.
  def praise?
    [ true, false, false, false ].sample
  end
end
