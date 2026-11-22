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
end
