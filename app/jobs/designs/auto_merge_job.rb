# Merges a design thread into master when its task's Jira issue reaches Done
# (Workshop Designs v2: "Merges automatically when <KEY> moves to Done"). Jira
# sync queues it (JiraSyncService#queue_design_merge). A thread whose branch
# collides with master is left open, and says why; one busy with a turn is
# tried again later.
class Designs::AutoMergeJob < ApplicationJob
  queue_as :designs

  CONFLICT = "Couldn't merge automatically: master changed the same lines. Update from master, then merge.".freeze

  BUSY = "Couldn't merge automatically: the thread stayed busy. Merge it by hand when its turn ends.".freeze

  retry_on Designs::Threads::Busy, wait: 2.minutes, attempts: 15 do |job, _error|
    thread = DesignThread.find_by(id: job.arguments.first)
    Designs::Threads.note(thread, BUSY) if thread&.open?
  end

  def perform(thread_id)
    thread = DesignThread.find_by(id: thread_id)
    return unless thread&.open? && !thread.fresh?

    Designs::Threads.merge!(thread, how: "auto")
  rescue Designs::Repo::Conflict
    Designs::Threads.note(thread, CONFLICT)
  rescue GitRunner::Error => e
    Designs::Threads.note(thread, "Couldn't merge automatically: #{e.message.to_s.lines.first.to_s.strip.truncate(300)}. Merge it by hand.")
  rescue Designs::Threads::AlreadyMerged, Designs::Threads::NothingToMerge
    nil
  end
end
