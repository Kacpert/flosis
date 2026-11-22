require "test_helper"

# Stopping an import (Kacper, 2026-11-22: "nie ma przycisku stop"): a running
# import fails as stopped, saying who stopped it, and the Claude of each of its
# turns goes; a finished import's queue fails feature by feature; an import
# with nothing under way is left alone.
class Designs::ImportStopTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @killed = []
    Designs::SetupRunJob.killer = ->(id) { @killed << id }
  end

  teardown { Designs::SetupRunJob.killer = nil }

  def turn_for(setup, status: "running", claude: SecureRandom.uuid)
    session = ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_setup",
                                  claude_session_id: claude, codebase_path: "/tmp", design_setup: setup)
    message = session.chat_messages.create!(role: "user", user: users(:one), content: "Build it.")
    DesignTurn.create!(chat_session: session, chat_message: message, kind: "setup", status: status)
  end

  test "stopping a running import fails it as stopped and kills its turns' Claude" do
    setup = @project.design_setups.create!(kind: "resync", status: "active", phase: "feature", step: 3, started_by: users(:one),
                                           unit_job_id: "job-1", unit_deadline_at: 10.minutes.from_now)
    turn = turn_for(setup, claude: "sess-1")
    done = turn_for(setup, status: "succeeded", claude: "sess-0")
    other = turn_for(@project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one)), claude: "sess-9")

    assert Designs::ImportStop.new(setup, users(:one)).stop!

    setup.reload
    assert_equal [ "failed", users(:one), nil, nil, nil ], [ setup.status, setup.stopped_by, setup.unit_job_id, setup.unit_deadline_at, setup.error ]
    assert setup.stopped?
    assert_equal [ "sess-1" ], @killed
    assert_equal [ "failed", "Stopped by Kacper." ], [ turn.reload.status, turn.error ]
    assert_equal [ "succeeded", "running" ], [ done.reload.status, other.reload.status ]
  end

  test "stopping a finished import's queue fails its queued and running features" do
    setup = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one),
                                           finished_at: 1.hour.ago, settled_at: 1.hour.ago)
    todo = setup.features.create!(name: "Library", key: "library", position: 1, status: "todo", queued_at: Time.current)
    running = setup.features.create!(name: "Billing", key: "billing", position: 2, status: "running", stage: "building")
    done = setup.features.create!(name: "Designs", key: "designs", position: 3, status: "done")
    turn_for(setup, claude: "sess-2")

    assert Designs::ImportStop.new(setup, users(:one)).stop!

    assert_equal %w[failed failed done], [ todo, running, done ].map { |feature| feature.reload.status }
    assert_equal [ "Stopped by Kacper.", nil ], [ todo.error, running.stage ]
    assert_equal "approved", setup.reload.status
    refute setup.stopped?
    assert_equal [ "sess-2" ], @killed
  end

  test "an import with nothing under way is left alone" do
    setup = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), finished_at: 1.hour.ago)

    refute Designs::ImportStop.new(setup, users(:one)).stop!
    assert_equal "approved", setup.reload.status
    assert_empty @killed
  end
end
