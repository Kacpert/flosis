class Brief < ApplicationRecord
  include VersionableDocument

  belongs_to :task
  belongs_to :workspace
  belongs_to :chat_session, optional: true

  STATUSES = %w[draft briefed].freeze

  validates :content, presence: true
  validates :version, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :newest_first, -> { order(version: :desc) }
  scope :draft, -> { where(status: "draft") }
  scope :briefed, -> { where(status: "briefed") }

  def self.next_version_for(task)
    (where(task: task).maximum(:version) || 0) + 1
  end

  def mark_briefed!
    update!(status: "briefed", briefed_at: Time.current)
  end

  def siblings_scope
    task.briefs
  end
end
