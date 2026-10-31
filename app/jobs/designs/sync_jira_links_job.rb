# Sends an approval's Web links to the task's Jira issue (Designs::JiraLinks)
# and records how that went on the approval: when they last went out, or why
# they did not, for the Designs screen to show and to retry.
class Designs::SyncJiraLinksJob < ApplicationJob
  queue_as :default

  def perform(approval_id)
    approval = DesignApproval.find_by(id: approval_id)
    return unless approval

    result = Designs::JiraLinks.new(approval.task).sync!
    if result[:ok]
      approval.update!(jira_links_synced_at: Time.current, jira_links_error: nil)
    else
      approval.update!(jira_links_error: result[:error].to_s.truncate(1_000))
    end
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] approval #{approval_id}: #{e.class}: #{e.message}")
    approval&.update!(jira_links_error: "The links could not be sent: #{e.class.name}")
  end
end
