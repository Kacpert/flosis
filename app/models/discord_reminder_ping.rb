class DiscordReminderPing < ApplicationRecord
  belongs_to :discord_reminder_recipient

  scope :since, ->(time) { where(sent_at: time..) }
end
