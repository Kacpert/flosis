require "test_helper"

# A deploy restarts the workers and kills the job that runs a setup's unit.
# Once the unit's deadline has passed, the run is picked up again where it
# was: its cut-off turn is failed, its unit freed, and its job enqueued.
class Designs::ResumeSetupsJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @project = projects(:jira_project) }

  def setup_turn(started_at:)
    session = ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_setup",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    message = session.chat_messages.create!(role: "user", content: "Build the feature", user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: message, kind: "setup", status: "running", started_at: started_at)
  end

  test "a stalled run is resumed at its feature, its cut-off turn failed" do
    stalled = @project.design_setups.create!(status: "active", phase: "feature", step: 4, unit_job_id: "gone", unit_deadline_at: 1.minute.ago)
    turn = setup_turn(started_at: 3.hours.ago)
    stalled.add_features!([ { "name" => "Timesheet" } ])
    stalled.features.first.update!(status: "running", design_turn: turn)
    live = @project.design_setups.create!(status: "active", phase: "feature", step: 4, unit_job_id: "alive", unit_deadline_at: 1.hour.from_now)

    assert_enqueued_with(job: Designs::SetupRunJob, args: [ stalled.id ]) { Designs::ResumeSetupsJob.perform_now }
    assert_equal 1, enqueued_jobs.count { _1["job_class"] == "Designs::SetupRunJob" }
    assert_nil stalled.reload.unit_job_id
    assert_equal [ "failed", DesignTurn::INTERRUPTED ], [ turn.reload.status, turn.error ]
    assert_equal "running", stalled.features.first.status, "the feature is built again from its start"
    assert_equal "alive", live.reload.unit_job_id
  end

  test "a finished or failed run is left alone" do
    @project.design_setups.create!(status: "failed", unit_job_id: "gone", unit_deadline_at: 1.minute.ago)
    @project.design_setups.create!(status: "approved", finished_at: Time.current, unit_job_id: "gone", unit_deadline_at: 1.minute.ago)
    assert_no_enqueued_jobs(only: Designs::SetupRunJob) { Designs::ResumeSetupsJob.perform_now }
  end
end
