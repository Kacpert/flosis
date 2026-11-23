# What Flosis sells an organization (SCRUM-70): a monthly price, which is the
# organization's monthly limit, a margin added to every run's reported cost,
# and the models it includes. In US dollars. The models restrict nothing yet.
class AiPlan < ApplicationRecord
  has_many :ai_plan_models, dependent: :destroy
  has_many :ai_models, through: :ai_plan_models
  has_many :workspaces, foreign_key: :ai_plan_id, dependent: :restrict_with_error, inverse_of: :ai_plan

  validates :name, presence: true
  validates :monthly_price_usd, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :margin_percent, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 }

  # A plan renamed or repriced moves this month's limit for everyone on it;
  # a closed month keeps the one it had (AiMonthLimit). A margin change needs
  # nothing: each run keeps the margin it was priced with. An organization that
  # paid for this month (SCRUM-71) keeps the limit it paid for: the new price
  # applies from its next charge.
  after_update_commit :refresh_month_limits, if: -> { saved_change_to_name? || saved_change_to_monthly_price_usd? }

  private

  def refresh_month_limits
    workspaces.includes(:billing_account).find_each do |workspace|
      AiMonthLimit.refresh_current!(workspace) unless workspace.billing_account&.plan_running?
    end
  end
end
