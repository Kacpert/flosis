# An organization. Which products it has is Flosis's call, made in /hidmin:
# hr_access (Time & HR, off for new organizations), workshop_enabled and
# clients_enabled.
class Workspace < ApplicationRecord
  has_many :workspace_memberships, dependent: :destroy
  has_many :users, through: :workspace_memberships
  has_many :clients, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :time_entries, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :integrations, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :feedback_meetings, dependent: :destroy

  has_many :holiday_requests, dependent: :destroy
  has_many :holiday_balance_entries, dependent: :destroy
  has_many :discord_reminder_recipients, dependent: :destroy
  has_many :pr_reviews, dependent: :delete_all
  has_many :discord_webhooks, dependent: :destroy
  has_many :alert_rules, dependent: :destroy

  # SCRUM-70: what its AI runs cost, against the plan Flosis assigned.
  belongs_to :ai_plan, optional: true
  has_many :ai_runs, dependent: :delete_all
  has_many :ai_month_limits, dependent: :delete_all

  # SCRUM-71: what it pays, and the invoices for it.
  has_one :billing_account, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :billing_charges, dependent: :destroy

  # Its organization administrators: they see Billing and Consumption, and get
  # every billing email.
  def admin_users
    User.where(id: workspace_memberships.where(workspace_admin: true).select(:user_id))
  end

  # Its billing row, made on first use.
  def billing
    billing_account || create_billing_account!(plan_state: ai_plan ? "pending" : "none")
  rescue ActiveRecord::RecordNotUnique
    reload.billing_account
  end

  validates :name, presence: true
end
