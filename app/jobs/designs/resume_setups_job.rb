# Picks setup runs up again after a deploy (the Designs setup, feature by
# feature). A deploy restarts the workers and kills the job that held a run's
# unit; once that unit's deadline has passed (its heartbeat stopped), the run
# is stalled. Under the run's lock, and only if it is still stalled, the
# Claude its killed attempt left is stopped, its setup turns still marked
# running are failed as interrupted, its unit is freed and its job enqueued:
# the run goes on from the step, or the feature, it was on.
# Runs every ten minutes, on the default queue, so a busy designs worker never
# holds it up.
class Designs::ResumeSetupsJob < ApplicationJob
  queue_as :default

  def perform
    DesignSetup.stalled.find_each do |setup|
      resumed = setup.with_lock do
        next false unless DesignSetup.stalled.exists?(setup.id)

        Designs::SetupRunJob.stop_attempts!(setup)
        setup.update!(unit_job_id: nil, unit_deadline_at: 1.second.ago)
        true
      end
      Designs::SetupRunJob.perform_later(setup.id) if resumed
    end
  end
end
