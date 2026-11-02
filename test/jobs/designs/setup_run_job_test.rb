require "test_helper"

# The Designs setup run, unattended (Workshop Designs v2), with the crawler and
# Claude stood in for: what each step leaves, where it stops on a failure, and
# a re-import that stops short of master.
class Designs::SetupRunJobTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    Designs::SetupRunJob.crawler = nil
    Designs::SetupRunJob.turn_runner = nil
  end

  # The crawl, as the crawler leaves it: a sealed folder with crawl.json.
  def fake_crawl(dir, error: nil)
    lambda do |setup_id|
      setup = DesignSetup.find(setup_id)
      next setup.update!(crawl_error: error) if error

      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "crawl.json"), { pages: [ { url: "/a" }, { url: "/b" }, { url: "/c" } ] }.to_json)
      setup.update!(crawl_dir: dir, crawled_at: Time.current)
    end
  end

  # A setup turn, as Claude leaves it: a commit on the run's branch.
  def fake_turn(repo, setup)
    lambda do |turn_id|
      branch = setup.reload.design_thread&.branch || "wip/setup"
      dir = repo.worktree!(branch, from: setup.design_thread&.base_sha || "master")
      commit_files(repo, dir, { "design-system/#{setup.phase}.css" => ":root { --#{setup.phase.dasherize}: 1; }" })
      repo.push!(branch)
      DesignTurn.find(turn_id).update!(status: "succeeded")
    end
  end

  def new_setup(project, thread: nil)
    project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p")
    project.design_setups.create!(status: "active", phase: "design_system", step: 0, started_by: users(:one), design_thread: thread)
  end

  test "the run goes through every step and lands on master as the initial import" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        repo.project.update!(design_repo_status: "ready")
        setup = new_setup(repo.project)
        Designs::SetupRunJob.crawler = fake_crawl(File.join(repo.project.designs_dir, "crawl"))
          Designs::SetupRunJob.turn_runner = fake_turn(repo, setup)
          Designs::SetupRunJob.perform_now(setup.id)

        setup.reload
        assert_equal [ "approved", 7, 3 ], [ setup.status, setup.step, setup.pages ], setup.error
        merge = repo.project.design_merges.sole
        assert_equal [ "setup", "Initial import from staging", "Flosis AI · setup" ], [ merge.how, merge.title, merge.how_label ]
        assert_equal remote_branch_sha(remote, "master"), merge.sha
        assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote), "design-system/components.css"
      end
    end
  end

  test "a failed step stops the run there, with its error, and Retry runs it again from that step" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        repo.project.update!(design_repo_status: "ready")
        setup = new_setup(repo.project)
        Designs::SetupRunJob.crawler = fake_crawl(nil, error: "The crawl could not sign in as Admin.")
          Designs::SetupRunJob.perform_now(setup.id)
        setup.reload
        assert_equal [ "failed", 1, "The crawl could not sign in as Admin." ], [ setup.status, setup.step, setup.error ]

        setup.update!(status: "active", crawl_error: nil)
        Designs::SetupRunJob.crawler = fake_crawl(File.join(repo.project.designs_dir, "crawl"))
          Designs::SetupRunJob.turn_runner = fake_turn(repo, setup)
          Designs::SetupRunJob.perform_now(setup.id)
        assert_equal "approved", setup.reload.status
      end
    end
  end

  test "a re-import works on its thread and leaves master alone" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        master = seed_master(repo)
        repo.project.update!(design_repo_status: "ready")
        thread = Designs::Threads.start!(project: repo.project, user: users(:one))
        thread.update!(title: "Re-import from staging", branch: "design/re-import-from-staging", base_sha: master)
        setup = new_setup(repo.project, thread: thread)
        Designs::SetupRunJob.crawler = fake_crawl(File.join(repo.project.designs_dir, "crawl"))
          Designs::SetupRunJob.turn_runner = fake_turn(repo, setup)
          Designs::SetupRunJob.perform_now(setup.id)

        assert_equal "approved", setup.reload.status
        assert_equal master, remote_branch_sha(remote, "master")
        assert remote_branch_sha(remote, "design/re-import-from-staging")
        assert_equal "Re-import from staging finished. Check what changed, then merge it.",
                     thread.chat_session.chat_messages.where(kind: "system").ordered.last.content
      end
    end
  end
end
