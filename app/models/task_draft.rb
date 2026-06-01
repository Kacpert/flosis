class TaskDraft < ApplicationRecord
  belongs_to :task

  # source distinguishes the kind of draft:
  #   "ai"        — a refined ticket description (markdown)
  #   "breakdown" — an estimate + sub-task breakdown (JSON, see BreakdownChatSessionsController)
  REFINE_SOURCE = "ai".freeze
  BREAKDOWN_SOURCE = "breakdown".freeze

  scope :newest_first, -> { order(created_at: :desc) }
  scope :by_source, ->(source) { where(source: source) }

  validates :content, presence: true
end
