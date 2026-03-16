class ChatSession < ApplicationRecord
  belongs_to :task
  belongs_to :workspace
  belongs_to :user

  has_many :chat_messages, dependent: :destroy

  validates :claude_session_id, presence: true
  validates :codebase_path, presence: true
  validates :status, presence: true, inclusion: { in: %w[active closed] }

  scope :active, -> { where(status: "active") }

  def self.find_active_for(task, user)
    active.find_by(task: task, user: user)
  end
end
