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

  # Configuration -> AI tab (Task 9.1): the built-in Jira field-name choices
  # offered as chips. A workspace may also have a custom (free-added) field
  # name stored in estimation_field_names that isn't in this list — the view
  # renders those as extra pre-checked chips alongside these options.
  ESTIMATION_FIELD_OPTIONS = [
    "AI estimation",
    "Story point estimate",
    "T-shirt size",
    "Confidence (1–5)"
  ].freeze

  ESTIMATION_TRIGGERS = {
    "sprint" => "Added to a Development sprint",
    "status" => "Status changes to “Ready for dev”",
    "briefed" => "AI actions = Briefed",
    "manual" => "Manually, on request"
  }.freeze

  # MySQL (prod) doesn't support JSON column defaults, so the default lives
  # here instead of in the migration (dev/test = PostgreSQL, prod = MySQL).
  #
  # MySQL also hands a :json column back as a raw JSON *string* in some cases
  # (PostgreSQL parses it to an Array). Normalize to an Array so callers/views
  # ("names - OPTIONS", "names.each") never get a String and 500.
  def estimation_field_names
    normalize_field_names(super)
  end

  def estimation_trigger_label
    ESTIMATION_TRIGGERS[estimation_trigger] || estimation_trigger
  end

  private

  def normalize_field_names(value)
    if value.is_a?(String)
      value = value.blank? ? nil : (JSON.parse(value) rescue value)
    end
    array = Array(value).reject { |v| v.nil? || v == "" }
    array.presence || [DEFAULT_ESTIMATION_FIELD_NAME]
  end
end
