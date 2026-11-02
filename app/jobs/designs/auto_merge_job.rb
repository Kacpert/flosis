# Merges a design thread into master when its task's Jira issue reaches Done
# (Workshop Designs v2: "Merges automatically when <KEY> moves to Done"). Jira
# sync queues it (JiraSyncService#queue_design_merge). A thread whose branch
# collides with master is left open, and says why; one busy with a turn is
# tried again later.
class Designs::AutoMergeJob < ApplicationJob
  queue_as :designs

  CONFLICT = "Couldn't merge automatically: master changed the same lines. Update from master, then merge.".freeze

  retry_on Designs::Threads::Busy, wait: 2.minutes, attempts: 15

  def perform(thread_id)
    thread = DesignThread.find_by(id: thread_id)
    return unless thread&.open? && !thread.fresh?

    Designs::Threads.merge!(thread, how: "auto")
  rescue Designs::Repo::Conflict
    Designs::Threads.note(thread, CONFLICT)
  rescue Designs::Threads::AlreadyMerged
    nil
  end
end
