class JiraComment < ApplicationRecord
  belongs_to :task

  scope :ordered, -> { order(jira_created_at: :asc) }
end
