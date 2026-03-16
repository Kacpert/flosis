class Project < ApplicationRecord
  belongs_to :workspace
  belongs_to :client, optional: true
  has_many :tasks, dependent: :destroy
  has_many :jira_boards, dependent: :destroy
  has_many :time_entries, dependent: :nullify
  has_many :project_memberships, dependent: :destroy
  has_many :members, through: :project_memberships, source: :user

  enum :budget_type, { no_budget: 0, money: 1, hours: 2 }

  validates :name, presence: true
  validates :color, presence: true, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }

  scope :active, -> { where(archived: false) }
  scope :archived, -> { where(archived: true) }

  def jira_connected?
    external_type == "jira"
  end

  CURRENCIES = %w[USD EUR GBP CAD AUD JPY CHF PLN].freeze

  PROJECT_COLORS = %w[
    #3B82F6 #EF4444 #10B981 #F59E0B #8B5CF6
    #EC4899 #06B6D4 #F97316 #84CC16 #6366F1
    #14B8A6 #E11D48 #A855F7 #0EA5E9 #D946EF
    #64748B
  ].freeze

  def budget_used_seconds
    time_entries.where.not(stopped_at: nil).sum(:duration_seconds)
  end

  def budget_used_cents
    time_entries.where.not(stopped_at: nil).sum("duration_seconds * COALESCE(hourly_rate_cents, 0) / 3600")
  end

  def budget_percentage
    case budget_type
    when "hours"
      return 0 if budget_hours.nil? || budget_hours.zero?
      (budget_used_seconds / 3600.0 / budget_hours * 100).round(1)
    when "money"
      return 0 if budget_cents.nil? || budget_cents.zero?
      (budget_used_cents.to_f / budget_cents * 100).round(1)
    else
      0
    end
  end
end
