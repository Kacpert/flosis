class JiraBoardColumn < ApplicationRecord
  belongs_to :jira_board
  has_many :jira_board_column_statuses, dependent: :destroy

  validates :name, presence: true
  validates :position, presence: true, uniqueness: { scope: :jira_board_id }

  # map, not pluck: pluck always re-queries, which defeats an `includes` and cost
  # one query per column when building the automations' board snapshot. A column
  # maps a handful of statuses, so loading them is cheaper than the round trips.
  def status_names
    jira_board_column_statuses.map(&:jira_status_name)
  end
end
