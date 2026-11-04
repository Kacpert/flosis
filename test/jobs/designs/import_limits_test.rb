require "test_helper"

# Designs imports: an import waits out Claude's session limit and goes on by
# itself where it stopped, instead of failing every feature after it; and an
# answer the CLI could not read is tried twice more before its feature
# couldn't finish. The sign-in, the app's repositories and Claude are stood
# in for.
class Designs::ImportLimitsTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  WARSAW = ActiveSupport::TimeZone["Europe/Warsaw"]
  LIMIT = "Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)".freeze

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    Designs::SetupRunJob.sign_in = ->(_setup) { { "1-admin" => true } }
    Designs::SetupRunJob.app_repos = ->(_setup) { [] }
    Designs::SetupRunJob.killer = ->(_session_id) {}
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    Designs::SetupRunJob.turn_runner = nil
    Designs::SetupRunJob.sign_in = nil
    Designs::SetupRunJob.app_repos = nil
    Designs::SetupRunJob.killer = nil
  end

  def running_import(repo, step:, features: [])
    project = repo.project
    project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ], design_repo_status: "ready")
    setup = project.design_setups.create!(status: "active", phase: "feature", step: step, started_by: users(:one))
    features.each_with_index { |name, i| setup.features.create!(name: name, key: name.parameterize, position: i + 1, contexts: %w[1-admin]) }
    setup
  end

  # Each turn, in order: an error to fail with, or nil to succeed.
  def turns(*outcomes)
    @turns = 0
    lambda do |turn_id|
      outcome = outcomes[@turns] || outcomes.last
      @turns += 1
      turn = DesignTurn.find(turn_id)
      outcome ? turn.update!(status: "failed", error: outcome) : turn.update!(status: "succeeded")
    end
  end

  test "a session limit pauses the run until it resets, then goes on with that feature" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = running_import(repo, step: 4, features: [ "Designs", "Profile" ])
        Designs::SetupRunJob.turn_runner = turns(LIMIT, nil)
        resets = WARSAW.local(2026, 11, 4, 8, 0)

        travel_to WARSAW.local(2026, 11, 4, 6, 50) do
          Designs::SetupRunJob.perform_now(setup.id)
          setup.reload
          designs = setup.features.first
          assert_equal [ "todo", resets ], [ designs.status, designs.resets_at ]
          assert_equal :paused, designs.problem
          assert_equal [ "active", resets, nil ], [ setup.status, setup.paused_until, setup.unit_job_id ]
          assert setup.paused?
          assert_equal "todo", setup.features.second.status, "nothing after it is tried meanwhile"
          assert_enqueued_with(job: Designs::SetupRunJob, args: [ setup.id ], at: resets)
        end

        travel_to WARSAW.local(2026, 11, 4, 8, 1) do
          Designs::SetupRunJob.perform_now(setup.id)
        end
        setup.reload
        designs = setup.features.first
        assert_equal [ "done", nil ], [ designs.status, designs.resets_at ]
        assert_nil setup.paused_until
        assert_equal 2, @turns
      end
    end
  end

  test "a limit in the map step pauses instead of failing the run" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = running_import(repo, step: 2)
        Designs::SetupRunJob.turn_runner = turns(LIMIT)

        travel_to WARSAW.local(2026, 11, 4, 6, 50) do
          Designs::SetupRunJob.perform_now(setup.id)
        end
        setup.reload
        assert_equal [ "active", 2, nil ], [ setup.status, setup.step, setup.error ]
        assert_equal WARSAW.local(2026, 11, 4, 8, 0), setup.paused_until
      end
    end
  end

  test "a paused run is not taken for stalled" do
    with_design_remote do |repo, _remote|
      setup = running_import(repo, step: 4, features: [ "Designs" ])
      setup.update!(paused_until: 1.hour.from_now, unit_job_id: nil, unit_deadline_at: 1.hour.from_now + Designs::SetupRunJob::UNIT_GRACE)

      Designs::ResumeSetupsJob.perform_now
      assert_no_enqueued_jobs only: Designs::SetupRunJob
    end
  end

  test "an unreadable answer is tried twice more before the feature couldn't finish" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = running_import(repo, step: 4, features: [ "Task workspace" ])
        Designs::SetupRunJob.turn_runner = turns("Failed to parse Claude response")

        3.times { Designs::SetupRunJob.perform_now(setup.id) }
        feature = setup.features.sole.reload
        assert_equal [ "failed", 2, "Failed to parse Claude response" ], [ feature.status, feature.attempts, feature.error ]
        assert_equal 3, @turns
        assert_equal [ "Could not finish: Failed to parse Claude response" ], feature.notes, "noted once, not per attempt"
      end
    end
  end
end
