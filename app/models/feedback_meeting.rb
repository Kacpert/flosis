class FeedbackMeeting < ApplicationRecord
  belongs_to :workspace
  belongs_to :creator, class_name: "User"
  belongs_to :employee, class_name: "User"

  validates :title, presence: true
  validates :scheduled_at, presence: true

  scope :for_employee, ->(user) { where(employee: user) }
  scope :recent, -> { order(scheduled_at: :desc) }
end
