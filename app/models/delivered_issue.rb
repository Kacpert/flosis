# Workshop-only reporting mirror of DONE Jira issues. Populated by
# JiraSyncService#sync_delivered_issues from a lightweight ~400-day
# "done issues" pass — NEVER from the open-issue pass that upserts `tasks`.
#
# HR-BOUNDARY: this table exists specifically so delivered (done) issues
# never land in `tasks` — HR's Projects index renders `project.tasks.size`,
# and syncing ~400 days of done work into `tasks` would silently change
# that headcount-adjacent number. Keep DeliveredIssue writes isolated from
# the Task model entirely.
class DeliveredIssue < ApplicationRecord
  belongs_to :project

  validates :jira_key, presence: true, uniqueness: { scope: :project_id }
end
