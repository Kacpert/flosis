# A superseded version of an AlertRule's prompt, written by AlertRule when the
# text changes. Never edited — it is a record of what the automation used to be
# told, so the live rule is the only thing anyone changes.
class AlertRulePromptVersion < ApplicationRecord
  belongs_to :alert_rule

  # created_at is set by hand (the table has no updated_at, and a version is
  # written inside the rule's own save).
  self.record_timestamps = false

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # A one-line hint of what this version said, for the list in the edit modal.
  def preview(limit = 110)
    prompt.to_s.squish.truncate(limit)
  end
end
