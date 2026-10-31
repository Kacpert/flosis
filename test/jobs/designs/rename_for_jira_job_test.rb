require "test_helper"

class Designs::RenameForJiraJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  # A task worked on and approved before it had a Jira key, now given REC-7.
  def keyless_task(repo)
    seed_master(repo)
    task = tasks(:jira_task)
    task.update!(project: repo.project, external_reference: nil)
    slug = "task-#{task.id}"
    sha = commit_files(repo, repo.worktree!("wip/#{slug}"), { "designs/tasks/#{slug}.json" => '{"screens":[]}' })
    repo.point!("design/#{slug}", to: sha)
    repo.tag!("approved/#{slug}/1", at: sha)
    repo.push!("wip/#{slug}", "design/#{slug}", "approved/#{slug}/1")
    task
  end

  test "branches, tags, the manifest and the previews move to the Jira key" do
    with_design_remote do |repo, remote|
      task = keyless_task(repo)
      slug = "task-#{task.id}"
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("design/#{slug}", slug)
      task.update!(external_reference: "REC-7")
      with_remote_url(remote) { Designs::RenameForJiraJob.perform_now(task.id) }
      assert remote_branch_sha(remote, "wip/REC-7")
      assert remote_branch_sha(remote, "design/REC-7")
      assert_nil remote_branch_sha(remote, "wip/#{slug}")
      assert_nil remote_branch_sha(remote, "design/#{slug}")
      assert_equal [ "approved/REC-7/1" ], repo.tags("approved/*")
      assert_equal "approved/REC-7/1", GitRunner.run!("tag", "-l", "approved/*", chdir: remote).strip
      assert repo.read_file("wip/REC-7", "designs/tasks/REC-7.json")
      assert_nil repo.read_file("wip/REC-7", "designs/tasks/#{slug}.json")
      token = repo.project.reload.design_preview_token
      assert File.exist?(File.join(@preview_root, token, "REC-7"))
      assert File.exist?(File.join(@preview_root, token, "wip", "REC-7"))
      assert_not File.exist?(File.join(@preview_root, token, slug))
    end
  end

  # Ruling P4-R2: the records name tags that exist.
  test "the approvals, the Designs chat and the Jira links follow the rename" do
    with_design_remote do |repo, remote|
      task = keyless_task(repo)
      slug = "task-#{task.id}"
      approval = task.design_approvals.create!(user: users(:one), number: 1, tag: "approved/#{slug}/1",
                                               design_sha: repo.head("design/#{slug}"), master_sha: repo.head("master"))
      session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                                    claude_session_id: SecureRandom.uuid, codebase_path: repo.worktree_path("wip/#{slug}").to_s)
      task.update!(external_reference: "REC-7")
      assert_enqueued_with(job: Designs::SyncJiraLinksJob, args: [ approval.id ]) do
        with_remote_url(remote) { Designs::RenameForJiraJob.perform_now(task.id) }
      end
      assert_equal "approved/REC-7/1", approval.reload.tag
      assert_equal repo.worktree_path("wip/REC-7").to_s, session.reload.codebase_path
      assert repo.worktree_path("wip/REC-7").exist?
    end
  end

  test "a task without a key, or without branches of its own, is left alone" do
    with_design_remote do |repo, remote|
      task = keyless_task(repo)
      with_remote_url(remote) { Designs::RenameForJiraJob.perform_now(task.id) }
      assert remote_branch_sha(remote, "wip/task-#{task.id}")

      other = repo.project.tasks.create!(name: "Never designed", external_reference: "REC-8")
      assert_nothing_raised { with_remote_url(remote) { Designs::RenameForJiraJob.perform_now(other.id) } }
      assert_nil remote_branch_sha(remote, "wip/REC-8")
    end
  end

  test "renaming shares the design turn's lock" do
    assert_equal Designs::TurnJob.concurrency_key_for(1), Designs::RenameForJiraJob.concurrency_key_for(1)
  end

  test "a rename and a turn of one task wait on the same Solid Queue key" do
    task = tasks(:jira_task)
    session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    turn = DesignTurn.create!(chat_session: session,
                              chat_message: session.chat_messages.create!(role: "user", content: "x", user: users(:one)))
    assert_equal Designs::TurnJob.new(turn.id).concurrency_key, Designs::RenameForJiraJob.new(task.id).concurrency_key
  end
end
