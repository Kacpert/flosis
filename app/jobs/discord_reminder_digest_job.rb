class DiscordReminderDigestJob < ApplicationJob
  queue_as :default

  # Per-person reminder lines (the offender is @-mentioned; never discloses the
  # threshold/hours). One is picked at random so the digest doesn't read canned.
  REMINDER_LINES = [
    "<@%<id>s> — some hours from the last 3 working days aren't logged yet 🙏",
    "<@%<id>s> — a few hours seem to be missing from the last 3 working days 🙂",
    "<@%<id>s> — please fill in the missing time from the last 3 working days 🙏",
    "<@%<id>s> — still some gaps in the last 3 working days, mind logging them? ⏰"
  ].freeze

  PRAISE_LINES = [
    "<@%<id>s> — time tracking looks great, keep it up! 🌟",
    "<@%<id>s> — all logged and sharp, nice work! 💪",
    "<@%<id>s> — spotless logging lately 👏",
    "<@%<id>s> — right on point, keep crushing it! 🚀"
  ].freeze

  # ~25% chance, rolled independently per doing-well user.
  def self.praise?
    [ true, false, false, false ].sample
  end

  def perform(workspace_id)
    workspace = Workspace.find_by(id: workspace_id)
    return unless workspace

    client = DiscordGroupClient.for(workspace)
    return unless client.configured?

    behind = []
    praise = []
    # Evaluate everyone fresh AT SEND TIME so we never nag someone who logged
    # during the delay, and only praise people who are genuinely caught up.
    workspace.discord_reminder_recipients.active.includes(:user).find_each do |recipient|
      if recipient.under_threshold_now?
        behind << recipient
      elsif self.class.praise?
        praise << recipient
      end
    end

    return if behind.empty? && praise.empty?

    message = build_message(behind, praise)
    client.post(message)
  end

  private

  def build_message(behind, praise)
    sections = []

    unless behind.empty?
      lines = behind.map do |r|
        r.discord_reminder_pings.create!(sent_at: Time.current)
        "#{format(REMINDER_LINES.sample, id: r.discord_user_id)} #{count_suffix(r)}"
      end
      sections << (["**Missing hours — please log your time:**"] + lines).join("\n")
    end

    unless praise.empty?
      lines = praise.map { |r| format(PRAISE_LINES.sample, id: r.discord_user_id) }
      sections << (["**Nice work this week 👏**"] + lines).join("\n")
    end

    sections.join("\n\n")
  end

  def count_suffix(recipient)
    week = recipient.discord_reminder_pings.since(Time.current.beginning_of_week).count
    month = recipient.discord_reminder_pings.since(Time.current.beginning_of_month).count
    "(reminder ##{week} this week, ##{month} this month)"
  end
end
