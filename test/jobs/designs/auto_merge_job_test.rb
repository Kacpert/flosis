require "test_helper"

class Designs::AutoMergeJobTest < ActiveSupport::TestCase
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

  def with_threads_remote
    with_design_remote do |repo, remote|
      with_remote_url(remote) { yield repo, remote }
    end
  end

  def thread_with_work(repo, files, task: nil, text: "Change it")
    thread = task ? Designs::Threads.start_from_task!(task, user: users(:one)) : Designs::Threads.start!(project: repo.project, user: users(:one))
    Designs::Threads.message!(thread, user: users(:one), text: text) unless task
    thread.reload
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), files)
    repo.push!(thread.branch)
    DesignTurn.update_all(status: "succeeded")
    thread
  end

  test "a thread whose task is Done merges into master by itself" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1040")
      thread = thread_with_work(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>" }, task: task)

      Designs::AutoMergeJob.perform_now(thread.id)

      merge = DesignMerge.last
      assert_equal [ "auto", "Auto · SP-1040 moved to Done" ], [ merge.how, merge.how_label ]
      assert thread.reload.merged?
    end
  end

  test "a thread that collides with master is not merged, and says why" do
    with_threads_remote do |repo, _|
      seed_master(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>\n<p>one</p>\n" })
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1040")
      waiting = thread_with_work(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>\n<p>mine</p>\n" }, task: task)
      other = thread_with_work(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>\n<p>theirs</p>\n" }, text: "Other")
      Designs::Threads.merge!(other, user: users(:one))

      Designs::AutoMergeJob.perform_now(waiting.id)

      assert waiting.reload.open?
      assert_equal Designs::AutoMergeJob::CONFLICT, waiting.chat_session.chat_messages.where(kind: "system").ordered.last.content
    end
  end

  test "a merge git cannot finish is said in the thread, not dropped" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1040")
      thread = thread_with_work(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>" }, task: task)
      hook = File.join(remote, "hooks", "pre-receive")
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)

      Designs::AutoMergeJob.perform_now(thread.id)

      assert thread.reload.open?
      assert_match(/\ACouldn't merge automatically: /, thread.chat_session.chat_messages.where(kind: "system").ordered.last.content)
    end
  end

  test "a Done thread whose turns made screens since makes components first, and merges after them" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1040")
      thread = thread_with_work(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>" }, task: task)
      DesignTurn.where(chat_session: thread.chat_session).update_all(commit_sha: "abc1234")

      Designs::AutoMergeJob.perform_now(thread.id)

      turn = DesignTurn.order(:id).last
      assert_equal [ "components", "auto" ], [ turn.kind, turn.then_merge ]
      assert_not thread.reload.merged?
    end
  end
end
