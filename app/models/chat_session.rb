class ChatSession < ApplicationRecord
  belongs_to :task
  belongs_to :workspace
  belongs_to :user

  # Declared before chat_messages on purpose: a turn points at the user's
  # message that started it, so destroying a session has to remove its turns
  # before it removes the messages, or the foreign key refuses.
  has_many :design_turns, dependent: :destroy
  has_many :chat_messages, dependent: :destroy

  # A chat session has a purpose: "refine" (improve the ticket description),
  # "breakdown" (estimate complexity + split into sub-tasks), "brief" (draft
  # the task's brief) or "designs" (make clickable designs for the task; each
  # message starts a DesignTurn). They are separate conversations so they don't
  # pollute each other's context.
  PURPOSES = %w[refine breakdown brief designs].freeze

  validates :claude_session_id, presence: true
  validates :codebase_path, presence: true
  validates :status, presence: true, inclusion: { in: %w[active closed] }
  validates :purpose, presence: true, inclusion: { in: PURPOSES }

  scope :active, -> { where(status: "active") }

  # Sessions are shared across the workspace: one active session per task +
  # purpose, whoever opens the chat sees the same conversation. `user` is the
  # current viewer, used to scope to the workspace.
  def self.find_active_for(task, user = nil, purpose: "refine")
    scope = active.where(task: task, purpose: purpose)
    scope = scope.where(workspace_id: user.workspaces.pluck(:id)) if user
    scope.order(created_at: :desc).first
  end
end
