class TaskDraft < ApplicationRecord
  belongs_to :task

  scope :newest_first, -> { order(created_at: :desc) }

  validates :content, presence: true
end
