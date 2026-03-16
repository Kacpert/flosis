class JiraBoardColumn < ApplicationRecord
  belongs_to :jira_board
  has_many :jira_board_column_statuses, dependent: :destroy

  validates :name, presence: true
  validates :position, presence: true, uniqueness: { scope: :jira_board_id }

  def status_names
    jira_board_column_statuses.pluck(:jira_status_name)
  end
end
