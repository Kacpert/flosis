class JiraBoard < ApplicationRecord
  belongs_to :project
  has_many :jira_sprints, dependent: :destroy
  has_many :jira_board_columns, -> { order(:position) }, dependent: :destroy

  validates :jira_board_id, presence: true, uniqueness: { scope: :project_id }
  validates :name, presence: true
  validates :board_type, presence: true, inclusion: { in: %w[scrum kanban] }
end
