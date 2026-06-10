class DiscordReminderRecipient < ApplicationRecord
  belongs_to :workspace
  belongs_to :user

  validates :discord_user_id, presence: true, format: { with: /\A\d+\z/, message: "must be a numeric Discord ID" }
  validates :min_daily_hours, numericality: { greater_than: 0 }
  validates :user_id, uniqueness: { scope: :workspace_id }

  scope :active, -> { where(active: true) }
end
