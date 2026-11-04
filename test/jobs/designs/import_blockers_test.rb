require "test_helper"

# Designs imports: the AI can stop one feature with a question only the
# person can answer (an integration not connected on the test account, data
# it cannot create), and the import goes on with the next. What the feature
# built so far waits on its own branch, never on master, until the person's
# answer lets it go on. The sign-in, the app's repositories and Claude are
# stood in for.
class Designs::ImportBlockersTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  QUESTION = "The Jira board was empty for every context. Connect Jira on the test project and tell me to go on.".freeze

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

  def import(repo, status:, step:, features:)
    project = repo.project
    project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ], design_repo_status: "ready")
    finished = status == "approved" ? 1.hour.ago : nil
    setup = project.design_setups.create!(status: status, phase: "feature", step: step, started_by: users(:one), finished_at: finished, settled_at: finished)
    features.each_with_index do |(name, more), i|
      setup.features.create!(name: name, key: name.parameterize, position: i + 1, contexts: %w[1-admin], **(more || {}))
    end
    setup
  end

  # Claude, as each feature's turn leaves it: its screen committed where the
  # turn works and pushed, a summary, and for the features named in blocked,
  # the question.
  def fake_turns(repo, setup, blocked: [])
    @requests = []
    @branches = []
    seen = Hash.new(0)
    lambda do |turn_id|
      turn = DesignTurn.find(turn_id)
      @requests << turn.chat_message.content
      feature = setup.reload.features.find_by!(status: "running")
      seen[feature.name] += 1
      branch = feature.branch.presence || setup.design_thread&.branch || Designs::BranchNames::SETUP
      @branches << branch
      commit_files(repo, repo.worktree!(branch, from: "master"), { "designs/admin/#{feature.key}.html" => "<h1>#{feature.name} #{@requests.size}</h1>" })
      repo.push!(branch)
      messages = turn.chat_session.chat_messages
      messages.create!(role: "assistant", kind: "summary", content: "Built #{feature.name}.")
      messages.create!(role: "assistant", kind: "blocked", content: QUESTION) if blocked.include?(feature.name) && seen[feature.name] == 1
      turn.update!(status: "succeeded", commit_sha: repo.head(branch))
    end
  end

  test "a feature the AI is blocked on waits with its question, and the run goes on" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = import(repo, status: "active", step: 4, features: [ [ "Jira Tasks board" ], [ "Reporting" ] ])
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, blocked: [ "Jira Tasks board" ])
        2.times { Designs::SetupRunJob.perform_now(setup.id) }

        board, reporting = setup.features.reload.to_a
        assert_equal [ "waiting", QUESTION ], [ board.status, board.question ]
        assert_equal :waiting, board.problem
        assert_equal "done", reporting.status
      end
    end
  end

  test "in the first import its partial work moves to its own branch, off wip/setup" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = import(repo, status: "active", step: 4, features: [ [ "Jira Tasks board" ], [ "Reporting" ] ])
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, blocked: [ "Jira Tasks board" ])
        Designs::SetupRunJob.perform_now(setup.id)

        board = setup.features.first.reload
        branch = "wip/import-#{setup.id}-jira-tasks-board"
        assert_equal branch, board.branch
        setup_files = GitRunner.run!("ls-tree", "-r", "--name-only", "wip/setup", chdir: remote)
        assert_not_includes setup_files, "designs/admin/jira-tasks-board.html", "nothing half-built goes to master with the import"
        assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", branch, chdir: remote), "designs/admin/jira-tasks-board.html"
        assert_equal remote_branch_sha(remote, "wip/setup"), repo.head("wip/setup")
      end
    end
  end

  test "an answer during the first import goes on from that branch and joins the import" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = import(repo, status: "active", step: 4, features: [ [ "Jira Tasks board" ], [ "Reporting" ] ])
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, blocked: [ "Jira Tasks board" ])
        Designs::SetupRunJob.perform_now(setup.id)
        board = setup.features.first.reload
        board.queue!(reply: "Connected it, go on.", fresh: false)
        2.times { Designs::SetupRunJob.perform_now(setup.id) }

        board.reload
        assert_equal [ "done", nil ], [ board.status, board.branch ]
        assert_equal [ "wip/setup", "wip/import-#{setup.id}-jira-tasks-board", "wip/setup" ], @branches,
                     "the board, the board again on its own branch, then Reporting"
        assert_includes @requests[1], "## You asked\n#{QUESTION}"
        assert_includes @requests[1], "## They replied\nConnected it, go on."
        assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "wip/setup", chdir: remote), "designs/admin/jira-tasks-board.html"
        assert_nil remote_branch_sha(remote, "wip/import-#{setup.id}-jira-tasks-board")
      end
    end
  end

  test "after the import a feature waits on its branch, and its answer lands it on master" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        setup = import(repo, status: "approved", step: 6, features: [ [ "Jira Tasks board", { status: "failed", error: "Failed to parse Claude response" } ] ])
        Designs::SetupRunJob.turn_runner = fake_turns(repo, setup, blocked: [ "Jira Tasks board" ])
        board = setup.features.sole
        board.queue!
        perform_enqueued_jobs(only: Designs::SetupRunJob) { setup.start_work! }

        board.reload
        assert_equal [ "waiting", "wip/import-#{setup.id}-jira-tasks-board" ], [ board.status, board.branch ]
        assert_empty repo.project.design_merges, "nothing half-built reaches master"
        board.queue!(reply: "Connected it.", fresh: false)
        perform_enqueued_jobs(only: Designs::SetupRunJob) { setup.start_work! }

        assert_equal "done", board.reload.status
        assert_equal [ "import" ], repo.project.design_merges.pluck(:how)
        assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote), "designs/admin/jira-tasks-board.html"
      end
    end
  end
end
