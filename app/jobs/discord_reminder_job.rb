class DiscordReminderJob < ApplicationJob
  queue_as :default

  WORKING_DAYS_WINDOW = 3
  # Each flagged person's message is sent at a random offset within this window
  # after the job runs, so the account behaves like a human rather than a bot
  # firing a burst at a fixed time.
  SPREAD = 120 # minutes

  # variant: "morning" (gentle wording) or "afternoon" (more urgent). Both spread
  # randomly over SPREAD minutes.
  def perform(variant = "morning")
    window = last_working_days(WORKING_DAYS_WINDOW)
    return if window.empty?

    # Each workspace stores its own Discord token/channel; only act on configured ones.
    Workspace.where.not(discord_user_token: nil).where.not(discord_channel_id: nil).find_each do |workspace|
      next unless DiscordGroupClient.for(workspace).configured?

      workspace.discord_reminder_recipients.active.includes(:user).find_each do |recipient|
        next unless under_threshold?(recipient, window)
        DiscordReminderMessageJob.set(wait: random_delay).perform_later(recipient.id, variant)
      end
    end
  end

  private

  # A random delay in [0, SPREAD] minutes so messages are spread out, not bursty.
  def random_delay
    rand(0..(SPREAD * 60)).seconds
  end

  # The last N working days (Mon–Fri) ending yesterday. The current day is never
  # included (it is still in progress).
  def last_working_days(count)
    days = []
    day = Date.yesterday
    while days.size < count
      days << day unless day.saturday? || day.sunday?
      day -= 1.day
    end
    days
  end

  def under_threshold?(recipient, window)
    eligible = window.reject { |d| on_approved_holiday?(recipient, d) }
    return false if eligible.empty?

    min_seconds = (recipient.min_daily_hours * 3600).to_i
    eligible.any? do |day|
      seconds = recipient.workspace.time_entries.completed
        .where(user_id: recipient.user_id)
        .for_date(day)
        .sum(:duration_seconds)
      seconds < min_seconds
    end
  end

  def on_approved_holiday?(recipient, day)
    HolidayRequest
      .where(workspace_id: recipient.workspace_id, user_id: recipient.user_id, status: :approved)
      .where("start_date <= ? AND end_date >= ?", day, day)
      .exists?
  end
end
