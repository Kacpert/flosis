class DiscordWebhook < ApplicationRecord
  belongs_to :workspace
  has_many :alert_rules, dependent: :restrict_with_error

  validates :channel_name, presence: true
  validates :url, presence: true
end
