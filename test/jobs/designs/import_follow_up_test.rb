require "test_helper"

# Designs imports: a feature of a finished import that is retried, answered
# or added is built after the import, one at a time, on a branch of its own
# off master, and lands on master by itself as an import merge. The sign-in,
# the app's repositories and Claude are stood in for.
class Designs::ImportFollowUpTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

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

  # The first import as it ended: features as [name, status, more].
  def finished_import(repo, features)
    project = repo.project
    project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ], design_repo_status: "ready")
    setup = project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one),
                                          finished_at: 1.hour.ago, settled_at: 1.hour.ago)
    features.each_with_index do |(name, status, more), i|
      setup.features.create!(name: name, key: name.parameterize, position: i + 1, status: status, contexts: %w[1-admin], **(more || {}))
    end
    setup
  end

  # Claude, as each feature's turn leaves it: the feature's screen committed
  # on its branch and pushed, and a summary. during: what else happens while
  # it builds.
  def fake_turns(repo, setup, during: nil)
    @requests = []
    @branches = []
    lambda do |turn_id|
      turn = DesignTurn.find(turn_id)
      @requests << turn.chat_message.content
      feature = setup.reload.features.find_by!(status: "running")
      @branches << feature.branch
      commit_files(repo, repo.worktree!(feature.branch, from: "master"), { "designs/admin/#{feature.key}.html" => "<h1>#{feature.name}</h1>" })
      repo.push!(feature.branch)
      during&.call(feature)
      turn.chat_session.chat_messages.create!(role: "assistant", kind: "summary", content: "Built #{feature.name} again.")
      turn.update!(status: "succeeded", commit_sha: repo.head(feature.branch))
    end
  end

  def run_work(setup)
    perform_enqueued_jobs(only: Designs::SetupRunJob) { setup.start_work! }
    setup.reload
  end

  test "a retried feature is built on its own branch and lands on master as an import merge" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = finished_import(repo, [ [ "App shell", "done" ], [ "Bug Reporting", "failed", { error: "Failed to parse Claude response" } ] ])
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        feature = setup.features.find_by!(name: "Bug Reporting")
        feature.queue!
        run_work(setup)

        feature.reload
        assert_equal "done", feature.status, feature.error
        assert_equal [ "wip/import-#{setup.id}-bug-reporting" ], @branches
        assert_match(/Build the feature "Bug Reporting"/, @requests.sole)
        assert_equal setup.id, feature.design_turn.chat_session.design_setup_id, "the turn knows its import"
        merge = repo.project.design_merges.sole
        assert_equal [ "import", "Bug Reporting", "wip/import-#{setup.id}-bug-reporting", "Built Bug Reporting again." ],
                     [ merge.how, merge.title, merge.branch, merge.summary ]
        assert_equal remote_branch_sha(remote, "master"), merge.sha
        assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote), "designs/admin/bug-reporting.html"
        assert_nil repo.head(merge.branch), "the branch is gone here"
        assert_nil remote_branch_sha(remote, merge.branch), "and on origin"
        assert_operator setup.settled_at, :>, 1.minute.ago, "the import settles"
        assert_nil setup.unit_job_id
      end
    end
  end

  test "words for the AI go with the retry" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = finished_import(repo, [ [ "Bug Reporting", "failed", { error: "Failed to parse Claude response" } ] ])
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        setup.features.sole.queue!(reply: "The Bugs page is under Reporting now.")
        run_work(setup)

        assert_includes @requests.sole, "## Before you start\nThe Bugs page is under Reporting now."
      end
    end
  end

  test "a reply goes on from the feature's branch with the question and the reply" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = finished_import(repo, [ [ "Jira Tasks board", "waiting", { question: "Connect Jira on the test project?" } ] ])
        feature = setup.features.sole
        branch = "wip/import-#{setup.id}-jira-tasks-board"
        commit_files(repo, repo.worktree!(branch, from: "master"), { "designs/admin/board.html" => "<h1>Half a board</h1>" })
        repo.push!(branch)
        feature.update!(branch: branch)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup)
        feature.queue!(reply: "Connected it, go on.", fresh: false)
        run_work(setup)

        assert_equal [ branch ], @branches
        assert_includes @requests.sole, "## You asked\nConnect Jira on the test project?"
        assert_includes @requests.sole, "## They replied\nConnected it, go on."
        files = GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote)
        assert_includes files, "designs/admin/board.html", "what it built before the question stays"
        assert_includes files, "designs/admin/jira-tasks-board.html"
      end
    end
  end

  test "the import settles once its last queued feature is done" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = finished_import(repo, [ [ "Designs", "failed", { error: "Failed to parse Claude response" } ],
                                        [ "Profile", "failed", { error: "Failed to parse Claude response" } ] ])
        settled = []
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, during: ->(_feature) { settled << setup.reload.settled_at })
        travel_to(10.minutes.from_now) { setup.features.each(&:queue!) }
        run_work(setup)

        assert_equal %w[done done], setup.features.map(&:status)
        assert_equal 2, repo.project.design_merges.where(how: "import").count, "each feature lands by itself"
        assert settled.all? { |time| time < 30.minutes.ago }, "it does not settle while features are still queued"
        assert_operator setup.settled_at, :>, 1.minute.ago
      end
    end
  end

  test "a feature that collides with master couldn't land, and says why" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = finished_import(repo, [ [ "Bug Reporting", "failed", { error: "Failed to parse Claude response" } ] ])
        meanwhile = ->(feature) { push_from_elsewhere(remote, "master", { "designs/admin/#{feature.key}.html" => "<h1>A thread's own</h1>" }) }
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, during: meanwhile)
        setup.features.sole.queue!
        run_work(setup)

        feature = setup.features.sole
        assert_equal [ "failed", Designs::ImportLanding::CONFLICT ], [ feature.status, feature.error ]
        assert_empty repo.project.design_merges
        assert_equal "<h1>A thread's own</h1>", GitRunner.run!("show", "master:designs/admin/bug-reporting.html", chdir: remote)
      end
    end
  end

  test "a follow-up a deploy cut off is picked up again" do
    with_design_remote do |repo, _remote|
      setup = finished_import(repo, [ [ "Bug Reporting", "running", { branch: "wip/import-1-bug-reporting" } ] ])
      setup.update!(unit_job_id: "gone", unit_deadline_at: 1.minute.ago)

      Designs::ResumeSetupsJob.perform_now
      assert_enqueued_with(job: Designs::SetupRunJob, args: [ setup.id ])
      assert_nil setup.reload.unit_job_id
    end
  end

  test "only one import unit runs at a time on the server" do
    with_design_remote do |repo, _remote|
      setup = finished_import(repo, [ [ "Bug Reporting", "todo", { queued_at: Time.current } ] ])
      other = projects(:plain_project).design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one),
                                                             unit_job_id: "busy", unit_deadline_at: 10.minutes.from_now)
      Designs::SetupRunJob.turn_runner = ->(_turn_id) { flunk "nothing is built while another import runs" }

      Designs::SetupRunJob.perform_now(setup.id)
      assert_equal "todo", setup.features.sole.reload.status
      assert_enqueued_with(job: Designs::SetupRunJob, args: [ setup.id ])
      assert_operator setup.reload.unit_deadline_at, :>, Time.current, "kept off the resume job while it waits its turn"
      assert_nil setup.unit_job_id
      assert_equal "busy", other.reload.unit_job_id
    end
  end
end
