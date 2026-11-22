require "test_helper"

# The Designs setup, feature by feature, with the repositories, the sign-in
# and Claude stood in for. The run goes one unit a job: it maps the features,
# builds the design system, builds the features one after another, notes a
# feature that fails and goes on, stops on what it cannot go past, takes its
# unit over when its job is delivered again, and lands on master (or, for a
# re-import, on its thread).
class Designs::SetupRunJobTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  FEATURES = [
    { "name" => "App shell", "contexts" => %w[1-admin], "screens" => [ "Home" ], "brief" => "Layout and navigation.", "notes" => [] },
    { "name" => "Timesheet", "contexts" => %w[1-admin], "screens" => [ "Week" ], "brief" => "Week view.", "notes" => [ "No entries in the test data." ] },
    { "name" => "Reports", "contexts" => %w[1-admin], "screens" => [ "Summary" ], "brief" => "Summary.", "notes" => [] }
  ].freeze

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    @signed_in = 0
    Designs::SetupRunJob.sign_in = ->(_setup) { @signed_in += 1; { "1-admin" => true } }
    Designs::SetupRunJob.app_repos = ->(_setup) { [ { "role" => "Frontend", "repo" => "acme/app", "branch" => nil, "dir" => "/tmp/app" } ] }
    @killed = []
    Designs::SetupRunJob.killer = ->(session_id) { @killed << session_id }
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    Designs::SetupRunJob.turn_runner = nil
    Designs::SetupRunJob.sign_in = nil
    Designs::SetupRunJob.app_repos = nil
    Designs::SetupRunJob.killer = nil
    Designs::SetupRunJob.heartbeat_every = nil
  end

  # Claude, as each setup turn leaves it: the map saves the features, the
  # design system and each feature commit files, and Reports leaves a note.
  # fail: the features whose turn fails.
  def fake_turns(repo, setup, fail: [], features: FEATURES)
    @requests = []
    lambda do |turn_id|
      turn = DesignTurn.find(turn_id)
      @requests << turn.chat_message.content
      setup.reload
      case setup.phase
      when "map"
        File.write(setup.run_dir.join("features.json"), features.to_json)
        turn.update!(status: "succeeded")
      when "design_system"
        commit(repo, setup, "design-system/theme.css" => ":root { --brand: 1; }")
        turn.update!(status: "succeeded", commit_sha: repo.head(branch(setup)))
      when "feature"
        feature = setup.features.find_by!(status: "running")
        next turn.update!(status: "failed", error: "Claude stopped with an error: overloaded") if fail.include?(feature.name)

        files = { "designs/admin/#{feature.key}.html" => %(<x-include src="components/button/button.html"></x-include>) }
        files["components/button/button.html"] = "<button></button>" if feature.position == 1
        commit(repo, setup, files)
        turn.chat_session.chat_messages.create!(role: "assistant", kind: "missing", content: "No reports in the test data.") if feature.name == "Reports"
        turn.update!(status: "succeeded", commit_sha: repo.head(branch(setup)))
      end
    end
  end

  def branch(setup) = setup.design_thread&.branch || "wip/setup"

  def commit(repo, setup, files)
    dir = repo.worktree!(branch(setup), from: setup.design_thread&.base_sha || "master")
    commit_files(repo, dir, files)
    repo.push!(branch(setup))
  end

  def new_setup(project, thread: nil)
    project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ], design_repo_status: "ready")
    project.design_setups.create!(status: "active", phase: "map", step: 0, started_by: users(:one), design_thread: thread)
  end

  # The run, every job it enqueues performed, until it is over.
  def run_to_the_end(setup)
    perform_enqueued_jobs(only: Designs::SetupRunJob) { Designs::SetupRunJob.perform_later(setup.id) }
    setup.reload
  end

  def job_as(setup, job_id)
    Designs::SetupRunJob.new(setup.id).tap { |job| job.job_id = job_id }
  end

  test "the run maps the features, builds each one and lands on master" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        run_to_the_end(setup)

        assert_equal [ "approved", 6 ], [ setup.status, setup.step ], setup.error
        assert_equal [ [ "App shell", "done" ], [ "Timesheet", "done" ], [ "Reports", "done" ] ], setup.features.map { [ _1.name, _1.status ] }
        assert_equal [ [ 1, 0 ], [ 0, 1 ], [ 0, 1 ] ], setup.features.map { [ _1.components_new, _1.components_reused ] }
        assert_equal [ [ "No entries in the test data." ], [ "No reports in the test data." ] ], setup.features.drop(1).map(&:notes)
        assert setup.features.all? { _1.design_turn&.setup? }, "each feature's turn is a setup turn"
        assert_equal 6, @signed_in, "the run signs in, then again before the map, the design system and every feature"
        assert_match(/Build the feature "Timesheet" \(2 of 3\)/, @requests[3])
        assert_equal 5, @requests.size
        sessions = setup.features.map { _1.design_turn.chat_session_id }
        assert_equal sessions.uniq, sessions, "each feature is a Claude session of its own"
        merge = repo.project.design_merges.sole
        assert_equal [ "setup", "Initial import from staging" ], [ merge.how, merge.title ]
        assert_equal remote_branch_sha(remote, "master"), merge.sha
        assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote), "designs/admin/reports.html"
        assert_nil setup.unit_job_id
        assert_equal 6, setup.step_seconds.compact.size
      end
    end
  end

  test "a feature whose turn fails is marked, and the run goes on" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, fail: [ "Timesheet" ])
        run_to_the_end(setup)

        assert_equal "approved", setup.status, setup.error
        assert_equal %w[done failed done], setup.features.map(&:status)
        assert_includes setup.features.second.notes, "Could not finish: Claude stopped with an error: overloaded"
        assert_equal "Couldn't finish", setup.features.second.label
      end
    end
  end

  # A deploy killed the job mid-unit: its Claude may still run, and its turn is
  # still marked running. The job delivered again stops both before it goes
  # on, so the commit is not refused over a turn nobody runs.
  test "a unit taken over stops the killed attempt's Claude and turn, and the run still lands on master" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        session = ChatSession.create!(project: repo.project, workspace: repo.project.workspace, user: users(:one), purpose: "designs_setup",
                                      claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
        message = session.chat_messages.create!(role: "user", content: "Map the app", user: users(:one))
        orphan = DesignTurn.create!(chat_session: session, chat_message: message, kind: "setup", status: "running", started_at: 1.minute.ago)
        setup.update!(unit_job_id: "job-a", unit_deadline_at: 1.hour.from_now)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        perform_enqueued_jobs(only: Designs::SetupRunJob) { job_as(setup, "job-a").perform_now }

        assert_includes @killed, session.claude_session_id
        assert_equal [ "failed", DesignTurn::INTERRUPTED ], [ orphan.reload.status, orphan.error ]
        assert_equal "approved", setup.reload.status, setup.error
      end
    end
  end

  test "the unit's claim is kept alive while it runs" do
    Designs::SetupRunJob.heartbeat_every = 0.05
    setup = new_setup(projects(:jira_project))
    deadlines = []
    Designs::SetupRunJob.app_repos = ->(run) { 3.times { sleep 0.15; deadlines << run.reload.unit_deadline_at }; [] }
    job_as(setup, "job-a").perform_now
    assert deadlines.each_cons(2).all? { |earlier, later| later > earlier }, "the deadline moves on while the unit runs: #{deadlines}"
  end

  test "a job delivered again takes its unit over, another one leaves it alone" do
    setup = new_setup(projects(:jira_project))
    setup.update!(unit_job_id: "job-a", unit_deadline_at: 1.hour.from_now)

    assert_no_enqueued_jobs(only: Designs::SetupRunJob) { job_as(setup, "job-b").perform_now }
    assert_equal [ 0, "job-a" ], [ setup.reload.step, setup.unit_job_id ]

    assert_enqueued_with(job: Designs::SetupRunJob, args: [ setup.id ]) { job_as(setup, "job-a").perform_now }
    assert_equal [ 1, nil ], [ setup.reload.step, setup.unit_job_id ]
    assert_empty @killed, "there was no attempt to stop"
  end

  test "a run nobody can sign in to stops, with the reason" do
    setup = new_setup(projects(:jira_project))
    Designs::SetupRunJob.sign_in = ->(_setup) { raise Designs::SignIn::Failure, "No context could sign in to the test environment: login failed." }
    run_to_the_end(setup)
    assert_equal [ "failed", 1, "No context could sign in to the test environment: login failed." ], [ setup.status, setup.step, setup.error ]
    assert_nil setup.unit_job_id
  end

  test "a map with no features stops the run" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, features: [])
        run_to_the_end(setup)
        assert_equal [ "failed", 2, "The map found no features." ], [ setup.status, setup.step, setup.error ]
      end
    end
  end

  test "a step whose turn fails stops the run there, and Retry goes on from it" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        Designs::SetupRunJob.turn_runner = ->(turn_id) { DesignTurn.find(turn_id).update!(status: "failed", error: "Out of time.") }
        run_to_the_end(setup)
        assert_equal [ "failed", 2, "Out of time." ], [ setup.status, setup.step, setup.error ]

        setup.update!(status: "active", error: nil)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        run_to_the_end(setup)
        assert_equal "approved", setup.status, setup.error
      end
    end
  end

  test "a re-import works on its thread and leaves master alone" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        master = seed_master(repo)
        thread = Designs::Threads.start!(project: repo.project, user: users(:one))
        thread.update!(title: "Re-import from staging", branch: "design/re-import-from-staging", base_sha: master)
        setup = new_setup(repo.project, thread: thread)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        run_to_the_end(setup)

        assert_equal "approved", setup.status, setup.error
        assert_equal master, remote_branch_sha(remote, "master")
        assert remote_branch_sha(remote, "design/re-import-from-staging")
        assert_equal "Re-import from staging finished. Check what changed, then merge it.",
                     thread.chat_session.chat_messages.where(kind: "system").ordered.last.content
      end
    end
  end

  # Kacper, 2026-11-22: what the job does after the person stopped the import
  # (its killed turn fails, a limit pauses it) must not undo the stop.
  test "the job's stop after the person's stop keeps the import as it was stopped, and lets its unit go" do
    setup = projects(:jira_project).design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one),
                                                          unit_job_id: "job-1", unit_deadline_at: 10.minutes.from_now)
    Designs::ImportStop.new(setup, users(:one)).stop!
    assert setup.reload.unit_live?, "the unit is the job's until it lets it go"

    job_as(setup, "job-1").send(:stop, setup.reload, "Claude could not finish this step.")
    setup.reload
    assert_equal [ "failed", nil, nil ], [ setup.status, setup.error, setup.unit_job_id ]
    assert setup.stopped?
  end

  test "a pause after a stop enqueues nothing" do
    setup = projects(:jira_project).design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one),
                                                          unit_job_id: "job-1", unit_deadline_at: 10.minutes.from_now)
    Designs::ImportStop.new(setup, users(:one)).stop!

    assert_no_enqueued_jobs(only: Designs::SetupRunJob) { Designs::SetupRunJob.new(setup.id).send(:pause, setup.reload, 1.hour.from_now) }
    assert_nil setup.reload.paused_until
  end

  # Kacper, 2026-11-22: what the browser cannot reach is built from the code,
  # and the feature says for which contexts.
  test "a feature records the contexts it was built from the code for" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        repo.project.design_setup_roles.create!(name: "Staff", code_only: true, position: 1)
        Designs::SetupRunJob.sign_in = ->(_setup) { { "1-admin" => true, "2-staff" => false } }
        features = FEATURES.map { |row| row.merge("contexts" => %w[1-admin 2-staff]) }
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, features: features)
        run_to_the_end(setup)

        assert_equal "approved", setup.status, setup.error
        assert_equal [ %w[2-staff] ], setup.features.map(&:from_code).uniq
      end
    end
  end

  # Kacper, 2026-11-22: what a turn needs from the person is left for them.
  test "a turn's suggestions become the import's" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = new_setup(repo.project)
        turns = fake_turns(repo, setup)
        Designs::SetupRunJob.turn_runner = lambda do |turn_id|
          if setup.reload.phase == "map"
            File.write(setup.run_dir.join("suggestions.jsonl"), [
              { kind: "context", title: "Flosis staff can see the Library", context: "Flosis staff", features: [ "library" ] }.to_json,
              { kind: "other", title: "No invoices on staging" }.to_json, "not json" ].join("\n"))
          end
          turns.call(turn_id)
        end
        run_to_the_end(setup)

        assert_equal [ [ "context", "Flosis staff" ], [ "other", nil ] ], setup.suggestions.order(:id).pluck(:kind, :context_name)
        refute setup.run_dir.join("suggestions.jsonl").exist?
      end
    end
  end

  # Final review C2 (2026-11-22): a Stop while a unit signs in (minutes, with
  # retries) ends the unit there: no turn starts, nothing lands.
  test "a Stop during a feature's sign-in builds nothing more" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed = seed_master(repo)
        setup = new_setup(repo.project)
        Designs::SetupRunJob.sign_in = lambda do |signing|
          Designs::ImportStop.new(signing, users(:one)).stop! if signing.reload.step == DesignSetup::FEATURES_STEP
          { "1-admin" => true }
        end
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        run_to_the_end(setup)

        assert setup.stopped?
        assert_equal 2, @requests.size, "the map and the design system only"
        assert_empty setup.features.where(status: %w[running done])
        assert_nil setup.unit_job_id
        assert_equal seed, remote_branch_sha(remote, "master"), "nothing reached master"
      end
    end
  end

  test "a Stop of a finished import's queue during its sign-in starts no turn" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        project = repo.project
        project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
        project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ], design_repo_status: "ready")
        import = project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), finished_at: 1.hour.ago, settled_at: 1.hour.ago)
        feature = import.features.create!(name: "Library", key: "library", position: 1, status: "todo", queued_at: Time.current, contexts: %w[1-admin])
        Designs::SetupRunJob.sign_in = ->(signing) { Designs::ImportStop.new(signing, users(:one)).stop!; { "1-admin" => true } }
        Designs::SetupRunJob.turn_runner = ->(_turn_id) { flunk "no turn after a Stop" }
        perform_enqueued_jobs(only: Designs::SetupRunJob) { import.start_work! }

        assert_equal [ "failed", "Stopped by Kacper." ], feature.reload.values_at(:status, :error)
        assert_equal "approved", import.reload.status
        assert_nil import.unit_job_id
      end
    end
  end
end
