class JiraSprint < ApplicationRecord
  belongs_to :jira_board

  validates :jira_sprint_id, presence: true, uniqueness: { scope: :jira_board_id }
  validates :name, presence: true
  validates :state, presence: true, inclusion: { in: %w[active closed future] }

  scope :active_or_future, -> { where(state: %w[active future]) }
end
