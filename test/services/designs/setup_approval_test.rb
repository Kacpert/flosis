require "test_helper"

class Designs::SetupApprovalTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  def task_on(repo)
    tasks(:jira_task).tap { _1.update!(project: repo.project, external_reference: "REC-1") }
  end

  def session_for(task)
    ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                        claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
  end

  def system_notes(session)
    session.chat_messages.where(kind: "system").ordered.pluck(:content)
  end

  def remote_files(remote, branch)
    GitRunner.run!("ls-tree", "-r", "--name-only", "refs/heads/#{branch}", chdir: remote).split("\n")
  end

  def preview(repo, *path)
    File.join(@preview_root, repo.project.reload.design_preview_token, *path)
  end

  def read_only(remote)
    FileUtils.chmod_R("a-w", remote)
    yield
  ensure
    FileUtils.chmod_R("u+w", remote)
  end

  # Plan 5: a setup run's approval.
  def setup_run(project)
    DesignSetup.create!(project: project, started_by: users(:one), phase: "feature")
  end

  def approve_setup(project, remote)
    with_remote_url(remote) { Designs::SetupApproval.new(project, user: users(:one)).approve! }
  end

  test "approving a setup merges wip/setup into master and tags approved/setup/1" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      setup = setup_run(repo.project)
      commit_files(repo, repo.worktree!("wip/setup"), { "design-system/tokens.css" => ":root {}" })
      repo.push!("wip/setup")
      number = approve_setup(repo.project, remote)
      assert_equal 1, number
      assert_includes remote_files(remote, "master"), "design-system/tokens.css"
      assert_equal "approved/setup/1", GitRunner.run!("tag", "-l", "approved/setup/*", chdir: remote).strip
      # Ruling P5-R7: wip/setup goes, here and on GitHub, in the same push.
      assert_nil remote_branch_sha(remote, "wip/setup")
      assert_nil repo.head("wip/setup")
      assert_not repo.worktree_path("wip/setup").exist?
      assert_equal [ "approved", true ], [ setup.reload.status, setup.approved_at.present? ]
      assert File.exist?(preview(repo, "master", "design-system", "tokens.css"))
    end
  end

  test "a new run after approval starts from master" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      setup_run(repo.project)
      commit_files(repo, repo.worktree!("wip/setup"), { "design-system/tokens.css" => ":root {}" })
      repo.push!("wip/setup")
      approve_setup(repo.project, remote)
      DesignSetup.create!(project: repo.project, started_by: users(:one))
      session = ChatSession.create!(project: repo.project, workspace: repo.project.workspace, user: users(:one),
                                    purpose: "designs_setup", claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
      dir = with_remote_url(remote) { Designs::Subject.for(session).checkout!(Designs::Repo.new(repo.project)) }
      assert_equal repo.head("master"), GitRunner.run!("rev-parse", "HEAD", chdir: dir).strip
    end
  end

  test "a setup with nothing new is not approved" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      setup = setup_run(repo.project)
      repo.worktree!("wip/setup")
      assert_raises(Designs::SetupApproval::NothingToApprove) { approve_setup(repo.project, remote) }
      assert_equal "active", setup.reload.status
    end
  end

  test "a setup push that fails leaves master, the tag and wip/setup as they were" do
    skip "root writes to a read-only remote" if Process.uid.zero?

    with_design_remote do |repo, remote|
      master = seed_master(repo)
      setup = setup_run(repo.project)
      work = commit_files(repo, repo.worktree!("wip/setup"), { "design-system/tokens.css" => ":root {}" })
      read_only(remote) { assert_raises(GitRunner::Error) { approve_setup(repo.project, remote) } }
      assert_equal master, repo.head("master")
      assert_equal [], repo.tags("approved/setup/*")
      assert_equal work, repo.head("wip/setup")
      assert_equal "active", setup.reload.status
    end
  end
end
