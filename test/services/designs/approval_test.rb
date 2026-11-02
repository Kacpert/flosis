require "test_helper"

class Designs::ApprovalTest < ActiveSupport::TestCase
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

  def approve(task, remote, **options)
    with_remote_url(remote) { Designs::Approval.new(task, user: users(:one), **options).approve! }
  end

  def update_from_master(task, remote)
    with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).update_from_master! }
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

  test "approving merges the work into master, moves the design branch, tags and publishes" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session = session_for(task)
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      approval = with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      assert_equal 1, approval.number
      assert_equal "approved/REC-1/1", approval.tag
      assert_equal wip, remote_branch_sha(remote, "design/REC-1")
      assert_equal approval.master_sha, remote_branch_sha(remote, "master")
      token = repo.project.reload.design_preview_token
      assert File.exist?(File.join(@preview_root, token, "REC-1", "designs", "jobs.html"))
      assert File.exist?(File.join(@preview_root, token, "master", "designs", "jobs.html"))
      assert_equal wip, approval.design_sha
      assert_equal users(:one), approval.user
      assert_equal approval.master_sha, GitRunner.run!("rev-parse", "approved/REC-1/1^{commit}", chdir: remote).strip
      assert_equal [ "Approved as version 1." ], system_notes(session)
    end
  end

  test "approving with nothing new is refused" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      assert_raises(Designs::Approval::NothingToApprove) do
        with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      end
      assert_equal 1, task.design_approvals.count
    end
  end

  test "a task with no working branch has nothing to approve" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      assert_raises(Designs::Approval::NothingToApprove) { approve(task, remote) }
    end
  end

  # Ruling P2-R4: a branch master already holds would make no merge commit.
  test "a branch master already holds is nothing to approve" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      repo.worktree!("wip/REC-1")
      assert_raises(Designs::Approval::NothingToApprove) { approve(task, remote) }
      assert_equal [], repo.tags("approved/REC-1/*")
    end
  end

  test "a second approval is version 2" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/a.html" => "1" })
      with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      commit_files(repo, dir, { "designs/a.html" => "2" })
      second = with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      assert_equal "approved/REC-1/2", second.tag
    end
  end

  # Ruling P2-R24: a failed push must not leave the design branch at the work
  # (every retry would be "nothing to approve") or a tag that never went out.
  test "a push that fails leaves the clone as it was, so the same work can be approved again" do
    skip "root writes to a read-only remote" if Process.uid.zero?

    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session = session_for(task)
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/a.html" => "1" })
      master = repo.head("master")
      read_only(remote) { assert_raises(GitRunner::Error) { approve(task, remote) } }
      assert_nil repo.head("design/REC-1")
      assert_equal [], repo.tags("approved/REC-1/*")
      assert_equal master, repo.head("master")

      first = approve(task, remote)
      assert_equal 1, first.number
      second_wip = commit_files(repo, dir, { "designs/a.html" => "2" })
      read_only(remote) { assert_raises(GitRunner::Error) { approve(task, remote) } }
      assert_equal first.design_sha, repo.head("design/REC-1")
      assert_equal [ "approved/REC-1/1" ], repo.tags("approved/REC-1/*")
      assert_equal first.master_sha, repo.head("master")

      second = approve(task, remote)
      assert_equal 2, second.number
      assert_equal second_wip, remote_branch_sha(remote, "design/REC-1")
      assert_equal [ "Approved as version 1.", "Approved as version 2." ], system_notes(session)
    end
  end

  test "work that collides with master is not approved, and master stays where it was" do
    with_design_remote do |repo, remote|
      seed_master(repo, { "designs/a.html" => "base\n" })
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n" })
      repo.push!("master")
      master = repo.head("master")
      assert_raises(Designs::Repo::Conflict) { approve(task, remote) }
      assert_equal master, remote_branch_sha(remote, "master")
      assert_nil repo.head("design/REC-1")
      assert_equal [], repo.tags("approved/REC-1/*")
      assert_equal 0, task.design_approvals.count
    end
  end

  # Ruling P2-R24: once the push is through, the approval is GitHub's fact and
  # Flosis keeps its record, whatever the publish does.
  test "an approval whose preview cannot be updated stands, and the chat says so" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session = session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      not_a_folder = File.join(@preview_root, "not-a-folder")
      File.write(not_a_folder, "")
      approval = with_env("DESIGNS_PREVIEW_ROOT" => not_a_folder) { approve(task, remote) }
      assert approval.persisted?
      assert_equal approval.master_sha, remote_branch_sha(remote, "master")
      assert_equal [ "Approved as version 1. The preview could not be updated, so it still shows the version before." ],
                   system_notes(session)
    end
  end

  test "nothing is approved or brought up to date while a turn of the task is queued or running" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session = session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      turn = DesignTurn.create!(chat_session: session,
                                chat_message: session.chat_messages.create!(role: "user", content: "More", user: users(:one)))
      assert_raises(Designs::Approval::TurnActive) { approve(task, remote) }
      assert_raises(Designs::Approval::TurnActive) { update_from_master(task, remote) }
      turn.start!
      assert_raises(Designs::Approval::TurnActive) { approve(task, remote) }
      assert_nil remote_branch_sha(remote, "design/REC-1")
      turn.succeed!(commit_sha: nil)
      assert_equal 1, approve(task, remote).number
    end
  end

  # Ruling P2-R26: a web request never waits behind a job.
  test "without waiting, approving while another holds the repo raises Busy and changes nothing" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      File.open(repo.root.dirname.join("design-repo.lock")) do |job|
        job.flock(File::LOCK_EX)
        assert_raises(Designs::Repo::Busy) { approve(task, remote, wait: false) }
      end
      assert_nil remote_branch_sha(remote, "design/REC-1")
      assert_equal 0, task.design_approvals.count
    end
  end

  test "the approval is posted in the task's Designs chat, which is made if it has none" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      approve(task, remote)
      session = ChatSession.find_by!(task: task, purpose: "designs")
      assert_equal [ "Approved as version 1." ], system_notes(session)
      assert_equal users(:one), session.user
    end
  end

  test "updating from master when nothing collides merges it in, pushes and publishes the branch" do
    with_design_remote do |repo, remote|
      seed_master(repo, { "designs/a.html" => "a\n" })
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/b.html" => "b\n" })
      commit_files(repo, repo.root, { "designs/c.html" => "c\n" })
      repo.push!("master")
      outcome = nil
      assert_no_enqueued_jobs(only: Designs::TurnJob) { outcome = update_from_master(task, remote) }
      assert_equal :merged, outcome
      assert_includes remote_files(remote, "wip/REC-1"), "designs/c.html"
      assert_includes remote_files(remote, "wip/REC-1"), "designs/b.html"
      assert File.exist?(preview(repo, "wip", "REC-1", "designs", "c.html"))
    end
  end

  test "updating from master with colliding files starts a resolving turn" do
    with_design_remote do |repo, remote|
      seed_master(repo, { "designs/a.html" => "base\n" })
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n" })
      repo.push!("master")
      # Ruling (Task 6): assert_enqueued_with returns the job, not the block's
      # value, so the outcome is taken inside the block.
      outcome = nil
      assert_enqueued_with(job: Designs::TurnJob) do
        outcome = with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).update_from_master! }
      end
      assert_equal :resolving, outcome
      assert_equal "resolve_conflicts", DesignTurn.last.kind
      assert_includes DesignTurn.last.chat_message.content, "designs/a.html"
    end
  end

  # Ruling P2-R25: the conflict is merged again by the turn itself, so nothing
  # of it waits in the worktree, where a turn queued before it would commit
  # the markers.
  test "a collision leaves the worktree as its branch has it, and the chat names the files" do
    with_design_remote do |repo, remote|
      seed_master(repo, { "designs/a.html" => "base\n" })
      task = task_on(repo)
      session = session_for(task)
      dir = repo.worktree!("wip/REC-1")
      wip = commit_files(repo, dir, { "designs/a.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n", "designs/new.html" => "new\n" })
      repo.push!("master")
      update_from_master(task, remote)
      assert_equal "task\n", dir.join("designs/a.html").read
      assert_not dir.join("designs/new.html").exist?
      assert_equal "", GitRunner.run!("status", "--porcelain", chdir: dir)
      assert_raises(GitRunner::Error) { GitRunner.run!("rev-parse", "--verify", "--quiet", "MERGE_HEAD", chdir: dir) }
      assert_equal wip, repo.head("wip/REC-1")
      assert_equal [ "Master changed the same files as this task: designs/a.html. Claude is resolving the conflicts." ],
                   system_notes(session)
      turn = DesignTurn.last
      assert turn.queued?
      assert_equal session, turn.chat_session
      assert_equal "user", turn.chat_message.role
      assert_equal users(:one), turn.chat_message.user
      assert_equal "Resolve the merge conflict markers in: designs/a.html. Keep this task's intent and master's newer changes.",
                   turn.chat_message.content
    end
  end

  def read_only(remote)
    FileUtils.chmod_R("a-w", remote)
    yield
  ensure
    FileUtils.chmod_R("u+w", remote)
  end

  test "an approval sends its Jira links afterwards" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      approval = nil
      assert_enqueued_with(job: Designs::SyncJiraLinksJob) { approval = approve(task, remote) }
      assert_enqueued_with(job: Designs::SyncJiraLinksJob, args: [ approval.id ])
    end
  end

  # Plan 5: a setup run's approval.
  def setup_run(project)
    DesignSetup.create!(project: project, started_by: users(:one), phase: "designs")
  end

  def approve_setup(project, remote)
    with_remote_url(remote) { Designs::Approval.for_setup(project, user: users(:one)).approve! }
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
      assert_raises(Designs::Approval::NothingToApprove) { approve_setup(repo.project, remote) }
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
