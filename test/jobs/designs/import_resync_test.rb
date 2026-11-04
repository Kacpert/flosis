require "test_helper"

# Designs imports: a resync, a new import started from the Imports page, finds
# what changed in the app since the last import (the features the changes
# touch and the ones that are new), builds each on its own branch off master
# and lands each there by itself. The sign-in, the app's repositories, their
# changes and Claude are stood in for.
class Designs::ImportResyncTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  ANALYSIS = [ { "key" => "bug-reporting", "contexts" => %w[1-admin], "screens" => [ "Bugs" ], "changes" => "A filter by status above the list." },
               { "name" => "Release notes", "contexts" => %w[1-admin], "screens" => [ "List" ], "brief" => "What shipped, newest first.",
                 "changes" => "A new page under Reporting." } ].freeze

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    Designs::SetupRunJob.sign_in = ->(_setup) { { "1-admin" => true } }
    Designs::SetupRunJob.app_repos = ->(_setup) { [ { "role" => "Frontend", "repo" => "acme/app", "branch" => nil, "dir" => "/tmp/app", "sha" => "b" * 40 } ] }
    Designs::SetupRunJob.killer = ->(_session_id) {}
    @changes_path = nil
    Designs::SetupRunJob.app_changes = lambda do |setup|
      FileUtils.mkdir_p(setup.run_dir.join("changes"))
      @changes_path = setup.run_dir.join("changes", "1-acme-app.diff").tap { |path| File.write(path, "+<form class=\"filter\"></form>\n") }.to_s
      [ { "repo" => "acme/app", "branch" => nil, "from" => "a" * 40, "to" => "b" * 40, "path" => @changes_path } ]
    end
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    %i[turn_runner sign_in app_repos killer app_changes].each { |seam| Designs::SetupRunJob.public_send("#{seam}=", nil) }
  end

  def first_import(repo)
    project = repo.project
    project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
    project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ], design_repo_status: "ready")
    setup = project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), created_at: Time.zone.local(2026, 11, 3, 1, 40),
                                          finished_at: 1.hour.ago, settled_at: 1.hour.ago, app_commits: [ { "repo" => "acme/app", "branch" => nil, "sha" => "a" * 40 } ])
    setup.features.create!(name: "Bug Reporting", key: "bug-reporting", position: 1, status: "done", contexts: %w[1-admin], screens: [ "Bugs" ], brief: "The stats and the trend.")
    setup
  end

  def resync_of(since)
    since.project.design_setups.create!(kind: "resync", since_setup: since, status: "active", phase: "resync", step: 0, started_by: users(:one))
  end

  # Claude: the analysis saves what changed; each feature's turn commits its
  # screen on its branch.
  def fake_turns(repo, setup, analysis: ANALYSIS)
    @requests = []
    lambda do |turn_id|
      turn = DesignTurn.find(turn_id)
      @requests << turn.chat_message.content
      case setup.reload.phase
      when "resync"
        File.write(setup.run_dir.join("features.json"), analysis.to_json)
      when "feature"
        feature = setup.features.find_by!(status: "running")
        commit_files(repo, repo.worktree!(feature.branch, from: "master"), { "designs/admin/#{feature.key}.html" => "<h1>#{feature.name}, as the app has it</h1>" },
                     message: "setup: Update #{feature.name}")
        repo.push!(feature.branch)
        turn.chat_session.chat_messages.create!(role: "assistant", kind: "summary", content: "Updated #{feature.name}.")
      end
      turn.update!(status: "succeeded", commit_sha: (repo.head(setup.features.find_by(status: "running")&.branch.to_s) if setup.phase == "feature"))
    end
  end

  def run_to_the_end(setup)
    perform_enqueued_jobs(only: Designs::SetupRunJob) { setup.start_work! }
    setup.reload
  end

  test "a resync finds the changed and new features, builds each on its own branch and lands each on master" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        resync = resync_of(first_import(repo))
        Designs::SetupRunJob.turn_runner = fake_turns(repo, resync)
        run_to_the_end(resync)

        assert_equal [ "approved", nil ], [ resync.status, resync.error ]
        assert_equal [ [ "bug-reporting", "changed", "done" ], [ "release-notes", "new", "done" ] ], resync.features.map { [ _1.key, _1.source, _1.status ] }
        assert_equal "1 updated · 1 new", resync.summary
        assert_equal "Changes since Nov 3", resync.title
        assert_equal [ "import", "import" ], repo.project.design_merges.pluck(:how)
        files = GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote)
        assert_includes files, "designs/admin/bug-reporting.html"
        assert_includes files, "designs/admin/release-notes.html"
        analysis = @requests.first
        assert_includes analysis, "- bug-reporting · Bug Reporting"
        assert_includes analysis, @changes_path
        assert_includes @requests.second, "Update the feature \"Bug Reporting\""
        assert_includes @requests.second, "What changed in its code since the last import:\nA filter by status above the list."
        assert_includes @requests.third, "It is new in the app since the last import."
        assert_equal [ { "repo" => "acme/app", "branch" => nil, "sha" => "b" * 40 } ], resync.app_commits
        assert resync.settled_at
      end
    end
  end

  test "a resync that finds nothing changed finishes with nothing to build" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        resync = resync_of(first_import(repo))
        Designs::SetupRunJob.app_changes = ->(_setup) { [ { "repo" => "acme/app", "branch" => nil, "from" => "a" * 40, "to" => "a" * 40, "path" => nil } ] }
        Designs::SetupRunJob.turn_runner = ->(_turn_id) { flunk "nothing to ask Claude" }
        run_to_the_end(resync)

        assert_equal [ "approved", [] ], [ resync.status, resync.features.to_a ]
        assert_equal [ "Nothing changed in the app's repositories since Nov 3." ], resync.notes.map { _1["text"] }
      end
    end
  end

  test "a newer resync replaces a proposal still waiting for the same feature" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        first = first_import(repo)
        older = repo.project.design_setups.create!(kind: "resync", since_setup: first, status: "approved", phase: "feature", step: 5, started_by: users(:one),
                                                   finished_at: 30.minutes.ago, settled_at: 30.minutes.ago)
        waiting = older.features.create!(name: "Bug Reporting", key: "bug-reporting", position: 1, status: "review", source: "changed",
                                         branch: "wip/import-#{older.id}-bug-reporting", review: { "comes_in" => [ "A filter." ] })
        commit_files(repo, repo.worktree!(waiting.branch, from: "master"), { "designs/admin/bugs.html" => "<h1>Old proposal</h1>" })
        repo.push!(waiting.branch)
        resync = resync_of(older)
        Designs::SetupRunJob.turn_runner = fake_turns(repo, resync)
        run_to_the_end(resync)

        waiting.reload
        assert_equal [ "set_aside", "Replaced by “Changes since #{older.created_at.strftime('%b %-d')}”" ], [ waiting.status, waiting.review["rejected"] ]
        assert_nil remote_branch_sha(remote, "wip/import-#{older.id}-bug-reporting")
      end
    end
  end
end
