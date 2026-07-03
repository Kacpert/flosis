class Workspace < ApplicationRecord
  has_many :workspace_memberships, dependent: :destroy
  has_many :users, through: :workspace_memberships
  has_many :clients, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :time_entries, dependent: :destroy
  has_many :integrations, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :feedback_meetings, dependent: :destroy

  has_many :holiday_requests, dependent: :destroy
  has_many :holiday_balance_entries, dependent: :destroy
  has_many :discord_reminder_recipients, dependent: :destroy
  has_many :pr_reviews, dependent: :delete_all
  has_many :discord_webhooks, dependent: :destroy
  has_many :alert_rules, dependent: :destroy

  validates :name, presence: true

  DEFAULT_ESTIMATION_FIELD_NAME = "AI estimation".freeze

  ESTIMATION_TRIGGERS = {
    "sprint" => "Added to a Development sprint",
    "status" => "Status changes to “Ready for dev”",
    "briefed" => "AI actions = Briefed",
    "manual" => "Manually, on request"
  }.freeze

  # MySQL (prod) doesn't support JSON column defaults, so the default lives
  # here instead of in the migration (dev/test = PostgreSQL, prod = MySQL).
  def estimation_field_names
    super.presence || [DEFAULT_ESTIMATION_FIELD_NAME]
  end

  def estimation_trigger_label
    ESTIMATION_TRIGGERS[estimation_trigger] || estimation_trigger
  end
end
