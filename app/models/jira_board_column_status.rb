class JiraBoardColumnStatus < ApplicationRecord
  belongs_to :jira_board_column

  validates :jira_status_name, presence: true
  validates :jira_status_id, presence: true, uniqueness: { scope: :jira_board_column_id }
end
