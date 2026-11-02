# Picks setup runs up again after a deploy (the Designs setup, feature by
# feature). A deploy restarts the workers and kills the job that held a run's
# unit; once that unit's deadline has passed, the run is stalled. Its setup
# turns still marked running are failed as interrupted, its unit is freed and
# its job enqueued: the run goes on from the step, or the feature, it was on.
# Runs every ten minutes, on the default queue, so a busy designs worker never
# holds it up.
class Designs::ResumeSetupsJob < ApplicationJob
  queue_as :default

  def perform
    DesignSetup.stalled.find_each do |setup|
      DesignTurn.joins(:chat_session).where(kind: "setup", status: DesignTurn::ACTIVE)
                .where(chat_sessions: { project_id: setup.project_id, purpose: "designs_setup" })
                .find_each { |turn| turn.fail!(DesignTurn::INTERRUPTED) }
      setup.release_unit!
      Designs::SetupRunJob.perform_later(setup.id)
    end
  end
end
