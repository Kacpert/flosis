class ChatSession < ApplicationRecord
  belongs_to :task
  belongs_to :workspace
  belongs_to :user

  has_many :chat_messages, dependent: :destroy

  validates :claude_session_id, presence: true
  validates :codebase_path, presence: true
  validates :status, presence: true, inclusion: { in: %w[active closed] }

  scope :active, -> { where(status: "active") }

  # Sessions are now shared across the workspace: one active session per
  # task, whoever opens the chat sees the same conversation. `user` is the
  # current viewer, used to scope to the workspace.
  def self.find_active_for(task, user = nil)
    scope = active.where(task: task)
    scope = scope.where(workspace_id: user.workspaces.pluck(:id)) if user
    scope.order(created_at: :desc).first
  end
end
