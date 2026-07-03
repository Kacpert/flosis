class AlertRun < ApplicationRecord
  belongs_to :alert_rule

  validates :status, inclusion: { in: %w[ok error] }

  scope :newest_first, -> { order(ran_at: :desc) }
end
