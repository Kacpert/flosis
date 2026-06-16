class DiscordReminderJob < ApplicationJob
  queue_as :default

  # The single daily digest is sent at a random offset within this window after
  # the 11:00 run, so the account behaves like a human rather than a bot firing
  # at a fixed minute. One message per day, somewhere in 11:00–13:00.
  SPREAD = 120 # minutes

  def perform
    # Each workspace stores its own Discord token/channel; only act on configured
    # ones. Enqueue ONE digest per workspace at a random moment in the window;
    # the digest job evaluates everyone fresh at send time and posts a single
    # combined message (reminders + praise).
    Workspace.where.not(discord_user_token: nil).where.not(discord_channel_id: nil).find_each do |workspace|
      next unless DiscordGroupClient.for(workspace).configured?

      DiscordReminderDigestJob.set(wait: random_delay).perform_later(workspace.id)
    end
  end

  private

  # A random delay in [0, SPREAD] minutes.
  def random_delay
    rand(0..(SPREAD * 60)).seconds
  end
end
