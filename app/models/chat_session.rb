class ChatSession < ApplicationRecord
  # A chat is about a task, or (a setup run's, purpose "designs_setup") about
  # a whole project: exactly one of the two.
  belongs_to :task, optional: true
  belongs_to :project, optional: true
  belongs_to :workspace
  belongs_to :user
  # A Designs setup turn's: the import it works for.
  belongs_to :design_setup, optional: true

  # Declared before chat_messages on purpose: a turn points at the user's
  # message that started it, so destroying a session has to remove its turns
  # before it removes the messages, or the foreign key refuses.
  has_many :design_turns, dependent: :destroy
  has_many :chat_messages, dependent: :destroy
  has_one :design_thread, dependent: :nullify

  # A chat session has a purpose: "refine" (improve the ticket description),
  # "breakdown" (estimate complexity + split into sub-tasks), "brief" (draft
  # the task's brief) or "designs" (make clickable designs for the task; each
  # message starts a DesignTurn). They are separate conversations so they don't
  # pollute each other's context.
  PURPOSES = %w[refine breakdown brief designs designs_setup designs_thread].freeze

  validates :claude_session_id, presence: true
  validates :codebase_path, presence: true
  validates :status, presence: true, inclusion: { in: %w[active closed] }
  validates :purpose, presence: true, inclusion: { in: PURPOSES }
  validate :task_or_project

  scope :active, -> { where(status: "active") }

  # Sessions are shared across the workspace: one active session per task +
  # purpose, whoever opens the chat sees the same conversation. `user` is the
  # current viewer, used to scope to the workspace.
  def self.find_active_for(task, user = nil, purpose: "refine")
    scope = active.where(task: task, purpose: purpose)
    scope = scope.where(workspace_id: user.workspaces.pluck(:id)) if user
    scope.order(created_at: :desc).first
  end

  # A setup run's chat: the project's one active designs_setup session, made
  # on first use by the person who started the run.
  def self.designs_setup_for!(project, user:, codebase_path:)
    active.where(project: project, purpose: "designs_setup").order(created_at: :desc).first ||
      create!(project: project, workspace: project.workspace, user: user, purpose: "designs_setup",
              claude_session_id: SecureRandom.uuid, codebase_path: codebase_path)
  end

  # A task's Designs chat. There is one per task, whoever opens it: its turns
  # share the task's worktree and one Claude session. It is made on first
  # use, by the person who opened it, in the workspace of the task's project.
  def self.designs_for!(task, user:, codebase_path:)
    find_active_for(task, purpose: "designs") ||
      create!(task: task, workspace: task.project.workspace, user: user, purpose: "designs",
              claude_session_id: SecureRandom.uuid, codebase_path: codebase_path)
  end

  private

  def task_or_project
    errors.add(:base, "A chat belongs to a task or to a project") unless task_id.present? ^ project_id.present?
  end
end
