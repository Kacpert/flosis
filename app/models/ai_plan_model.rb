class AiPlanModel < ApplicationRecord
  belongs_to :ai_plan
  belongs_to :ai_model

  validates :ai_model_id, uniqueness: { scope: :ai_plan_id }
end
