# AI "forensic engineer" verdict on where a bug originated, keyed by
# [project_id, jira_key] rather than a task reference — see the migration
# comment: a bug is analyzed while OPEN (a row in `tasks`), but once FIXED it
# only exists in `delivered_issues` (Task 6.2's HR-boundary mirror). Keying by
# jira_key lets a single BugAttribution row survive that move; `task` is a
# nullable pointer to the open task while it still exists.
#
# Populated by BugAttributionJob (git log/blame/grep analysis via the Claude
# CLI) and, in future, re-triggerable by a manual "Analyze" button when
# status is "failed".
class BugAttribution < ApplicationRecord
  belongs_to :project
  belongs_to :task, optional: true

  STATUSES = %w[pending done failed].freeze
  ORIGIN_KINDS = %w[new_functionality existing_code].freeze
  CONFIDENCES = %w[high medium low].freeze

  validates :jira_key, presence: true, uniqueness: { scope: :project_id }
  validates :status, inclusion: { in: STATUSES }
  validates :origin_kind, inclusion: { in: ORIGIN_KINDS }, allow_blank: true
  validates :confidence, inclusion: { in: CONFIDENCES }, allow_blank: true
end
