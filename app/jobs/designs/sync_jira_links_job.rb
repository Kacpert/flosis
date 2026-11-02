# Sends a task's design links to its Jira issue (Designs::JiraLinks), after
# its design thread changed or merged. A failure is said in the thread, for
# the next change to try again.
class Designs::SyncJiraLinksJob < ApplicationJob
  queue_as :default

  QUIET = [ Designs::JiraLinks::NO_JIRA, Designs::JiraLinks::NO_ISSUE ].freeze

  def perform(task_id)
    task = Task.find_by(id: task_id) or return
    result = Designs::JiraLinks.new(task).sync!
    return if result[:ok] || QUIET.include?(result[:error])

    note(task, "The Jira links could not be updated: #{result[:error].to_s.truncate(500)}")
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] task #{task_id}: #{e.class}: #{e.message}")
    note(task, "The Jira links could not be updated: #{e.class.name}") if task
  end

  private

  def note(task, text)
    thread = task.design_thread
    Designs::Threads.note(thread, text) if thread&.chat_session
  end
end
