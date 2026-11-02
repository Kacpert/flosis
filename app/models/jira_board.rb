class JiraBoard < ApplicationRecord
  belongs_to :project
  has_many :jira_sprints, dependent: :destroy
  has_many :jira_board_columns, -> { order(:position) }, dependent: :destroy

  validates :jira_board_id, presence: true, uniqueness: { scope: :project_id }
  validates :name, presence: true
  # Jira's board types: a company-managed project's scrum or kanban board, and
  # a team-managed project's "simple" one (which may run sprints too).
  TYPES = %w[scrum kanban simple].freeze

  validates :board_type, presence: true, inclusion: { in: TYPES }
end
