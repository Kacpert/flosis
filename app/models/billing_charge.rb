# One attempt to take money from an organization's card (SCRUM-71): the plan on
# the 1st or on activation, an upgrade's difference, a top-up bought by hand or
# automatically. Amounts are computed by Flosis before Stripe is asked; only a
# succeeded charge is invoiced. A failed plan charge is retried over 7 days.
class BillingCharge < ApplicationRecord
  KINDS = %w[plan upgrade top_up auto_top_up].freeze
  STATUSES = %w[pending requires_action succeeded failed abandoned].freeze

  belongs_to :workspace
  belongs_to :ai_plan, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  has_one :invoice, dependent: :restrict_with_error

  # Where 3-D Secure continues, when Stripe asked for it (not stored).
  attr_accessor :redirect_url

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :vat_treatment, inclusion: { in: %w[pl_23 eu_reverse_charge non_eu] }
  validates :net_usd, :vat_usd, :gross_usd, presence: true

  scope :succeeded, -> { where(status: "succeeded") }
  scope :failed, -> { where(status: "failed") }
  scope :plan_charges, -> { where(kind: "plan") }
  scope :top_ups, -> { where(kind: %w[top_up auto_top_up]) }
  scope :automatic_top_ups, -> { where(kind: "auto_top_up") }
  scope :for_month, ->(date) { where(period_month: date.beginning_of_month) }
  scope :charged_in_month, ->(date) { where(succeeded_at: date.in_time_zone.all_month) }

  def succeeded?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end

  def top_up?
    kind.in?(%w[top_up auto_top_up])
  end

  # "Plan" or "Top-up", as the invoice list says.
  def type_label
    top_up? ? "Top-up" : "Plan"
  end

  def cents
    (gross_usd * 100).round.to_i
  end

  # Day 1 is the day the first attempt failed.
  def retry_day(today = Date.current)
    return nil unless first_failed_at

    (today - first_failed_at.in_time_zone.to_date).to_i + 1
  end

  def retry_until
    first_failed_at && (first_failed_at.in_time_zone.to_date + (Billing::RETRY_DAYS - 1))
  end

  # Past the 7 days of retries, still not paid.
  def unpaid?(today = Date.current)
    failed? && retry_day(today).to_i > Billing::RETRY_DAYS
  end

  # What AI may use this month while the charge is retried: 15% of the plan price.
  def grace_usd
    (plan_price_usd.to_d * Billing::RETRY_GRACE_SHARE).round(2)
  end
end
