require "test_helper"

class Designs::ThreadsTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    @user = users(:one)
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  # The services make their own Designs::Repo, so the stand-in for GitHub is
  # set for every repo, not only the one the test holds.
  def with_threads_remote
    with_design_remote do |repo, remote|
      with_remote_url(remote) { yield repo, remote }
    end
  end

  def system_lines(thread)
    thread.chat_session.chat_messages.where(kind: "system").order(:id).pluck(:content)
  end

  # A thread whose branch has one commit of its own, pushed, as a turn leaves it.
  def thread_with_work(repo, text, files)
    thread = Designs::Threads.start!(project: repo.project, user: @user)
    Designs::Threads.message!(thread, user: @user, text: text)
    thread.reload
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), files)
    repo.push!(thread.branch)
    DesignTurn.where(chat_session: thread.chat_session).update_all(status: "succeeded")
    thread
  end

  test "a new thread is fresh until its first message names its branch from master" do
    with_threads_remote do |repo, _|
      base = seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      assert thread.fresh?
      assert_equal "New thread", thread.title

      turn = Designs::Threads.message!(thread, user: @user, text: "Let recruiters move several candidates at once",
                                       context: "recruiter", screen: "pipeline")
      thread.reload
      assert_equal "design/let-recruiters-move-several", thread.branch
      assert_equal "Let recruiters move several candidates at once", thread.title
      assert_equal base, thread.base_sha
      assert_equal [ "recruiter", "pipeline" ], [ thread.focus_context, thread.focus_screen ]
      assert_equal [ "Branch design/let-recruiters-move-several created from master #{base.first(7)}" ], system_lines(thread)
      assert_enqueued_with(job: Designs::TurnJob, args: [ turn.id ])
    end
  end

  test "a thread started from a task carries its key, its description, and starts designing" do
    with_threads_remote do |repo, _|
      base = seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1051", name: "Inline validation on question editor",
                   description: "Validate on blur")
      thread = Designs::Threads.start_from_task!(task, user: @user)

      assert_equal "design/SP-1051-inline-validation-on-question", thread.branch
      assert_equal task, thread.task
      assert_equal "Validate on blur", thread.described_text
      assert_equal [ "Thread started from SP-1051 · branch #{thread.branch} created from master #{base.first(7)}" ], system_lines(thread)
      assert_enqueued_jobs 1, only: Designs::TurnJob
    end
  end

  test "a changed description shows as a diff, and updating designs from it queues a turn" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1051", description: "Validate on blur")
      thread = Designs::Threads.start_from_task!(task, user: @user)
      assert_nil Designs::Threads.description_change(thread)

      task.update!(description: "Validate on blur\nShow a counter under long answers")
      change = Designs::Threads.description_change(thread)
      assert_equal [ [ "+", "Show a counter under long answers" ] ], change[:lines]

      clear_enqueued_jobs
      Designs::Threads.update_description!(thread, user: @user)
      diff = thread.chat_session.chat_messages.find_by!(kind: "diff")
      assert_equal "SP-1051 description changed · #{change[:from]} → #{change[:to]}", diff.content
      assert_equal [ [ "+", "Show a counter under long answers" ] ], diff.data["lines"]
      assert_nil Designs::Threads.description_change(thread.reload)
      assert_enqueued_jobs 1, only: Designs::TurnJob
    end
  end

  test "merging writes a merge commit on master, records it, publishes master and closes the thread" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours on pipeline", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      merge = Designs::Threads.merge!(thread, user: @user)

      assert_equal remote_branch_sha(remote, "master"), merge.sha
      assert_equal [ "manual", "Stage colours on pipeline", thread.branch, [ "admin/pipeline" ] ],
                   [ merge.how, merge.title, merge.branch, merge.screens ]
      assert thread.reload.merged?
      assert_equal merge.sha, thread.merged_sha
      assert_includes system_lines(thread), "Merged into master as #{merge.short_sha} by #{@user.name}"
      assert Pathname(@preview_root).join(repo.project.reload.design_preview_token, "master/designs/admin/pipeline.html").exist?
    end
  end

  test "a thread falls behind every merge that lands on master after its base" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      waiting = thread_with_work(repo, "Closing date reminders", { "designs/candidate/apps.html" => "<title>Apps</title>" })
      other = thread_with_work(repo, "Stage colours on pipeline", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      assert_empty Designs::Threads.behind(waiting)

      merge = Designs::Threads.merge!(other, user: @user)
      assert_equal [ merge ], Designs::Threads.behind(waiting.reload)
    end
  end

  test "a merge is refused while a turn of the thread is queued or running, and a merged thread is not merged again" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      DesignTurn.where(chat_session: thread.chat_session).update_all(status: "queued")
      assert_raises(Designs::Threads::Busy) { Designs::Threads.merge!(thread, user: @user) }

      DesignTurn.where(chat_session: thread.chat_session).update_all(status: "succeeded")
      Designs::Threads.merge!(thread, user: @user)
      assert_raises(Designs::Threads::AlreadyMerged) { Designs::Threads.merge!(thread.reload, user: @user) }
    end
  end

  test "update from master brings master in, says what came, moves the base and queues a check turn" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      waiting = thread_with_work(repo, "Closing date reminders", { "designs/candidate/apps.html" => "<title>Apps</title>" })
      other = thread_with_work(repo, "Stage colours on pipeline", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      DesignTurn.update_all(status: "succeeded")
      merge = Designs::Threads.merge!(other, user: @user)
      clear_enqueued_jobs
      base_before = waiting.reload.base_sha

      Designs::Threads.update_master!(waiting, user: @user)
      waiting.reload
      assert_equal repo.head("master"), waiting.base_sha
      assert_empty Designs::Threads.behind(waiting)
      assert_includes repo.ls_files(waiting.branch, "designs/"), "designs/admin/pipeline.html"
      came = waiting.chat_session.chat_messages.find_by!(kind: "master")
      assert_equal [ merge.sha ], came.data["merges"].map { |m| m["sha"] }
      assert_equal "master #{base_before.first(7)} → #{repo.head('master').first(7)} brought into this branch", came.content
      assert_enqueued_jobs 1, only: Designs::TurnJob
      assert_equal "design", DesignTurn.order(:id).last.kind
    end
  end

  test "update from master that collides queues a turn to resolve it" do
    with_threads_remote do |repo, _|
      seed_master(repo, { "designs/admin/pipeline.html" => "<title>Pipeline</title>\n<p>one</p>\n" })
      waiting = thread_with_work(repo, "First", { "designs/admin/pipeline.html" => "<title>Pipeline</title>\n<p>mine</p>\n" })
      other = thread_with_work(repo, "Second", { "designs/admin/pipeline.html" => "<title>Pipeline</title>\n<p>theirs</p>\n" })
      DesignTurn.update_all(status: "succeeded")
      Designs::Threads.merge!(other, user: @user)
      clear_enqueued_jobs

      Designs::Threads.update_master!(waiting.reload, user: @user)
      assert_equal "resolve_conflicts", DesignTurn.order(:id).last.kind
      assert_enqueued_jobs 1, only: Designs::TurnJob
    end
  end

  test "a turn a deploy killed stops keeping the thread busy" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      DesignTurn.where(chat_session: thread.chat_session).update_all(status: "running", started_at: 3.hours.ago)

      Designs::Threads.merge!(thread, user: @user)
      assert thread.reload.merged?
      assert DesignTurn.where(chat_session: thread.chat_session).all?(&:failed?)
    end
  end


  test "a thread with no changes of its own has nothing to merge, and says so" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      Designs::Threads.message!(thread, user: @user, text: "Nothing yet")
      DesignTurn.update_all(status: "succeeded")

      error = assert_raises(Designs::Threads::NothingToMerge) { Designs::Threads.merge!(thread.reload, user: @user) }
      assert_equal Designs::Threads::NOTHING_TO_MERGE, error.message
      assert thread.reload.open?
    end
  end

  test "a push GitHub refuses leaves master as it was and records nothing" do
    with_threads_remote do |repo, remote|
      before = seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      hook = File.join(remote, "hooks", "pre-receive")
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)

      assert_raises(GitRunner::Error) { Designs::Threads.merge!(thread, user: @user) }
      assert_equal before, repo.head("master")
      assert_equal before, remote_branch_sha(remote, "master")
      assert_empty DesignMerge.all
      assert thread.reload.open?
    end
  end


  test "how far behind a thread is never waits on the repo's lock" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      holder = Thread.new { Designs::Repo.new(repo.project).synchronize { sleep 3 } }
      sleep 0.3
      assert_equal [], Timeout.timeout(1.5) { Designs::Threads.behind(thread) }
    ensure
      holder&.join
    end
  end


  # A commit on a thread's branch made on GitHub (a developer, another clone).
  def commit_on_github(remote, branch, files)
    Dir.mktmpdir("github") do |dir|
      system("git", "clone", "--quiet", "--branch", branch, remote, dir, exception: true, err: File::NULL)
      files.each { |path, body| FileUtils.mkdir_p(File.dirname(File.join(dir, path))); File.write(File.join(dir, path), body) }
      system("git", "-C", dir, "add", "-A", exception: true)
      system("git", "-C", dir, "-c", "user.name=Dev", "-c", "user.email=dev@example.com", "commit", "--quiet", "-m", "On GitHub", exception: true)
      system("git", "-C", dir, "push", "--quiet", "origin", branch, exception: true, err: File::NULL)
    end
  end

  test "a branch that moved on GitHub is followed, so nothing made there is lost" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      commit_on_github(remote, thread.branch, { "designs/admin/extra.html" => "<title>Extra</title>" })

      Designs::Threads.merge!(thread, user: @user)
      assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote), "designs/admin/extra.html"
    end
  end

  test "a branch that moved both on GitHub and here stops the merge, saying so" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      commit_on_github(remote, thread.branch, { "designs/admin/extra.html" => "<title>Extra</title>" })
      commit_files(repo, repo.worktree_path(thread.branch), { "designs/admin/local.html" => "<title>Local</title>" })

      assert_raises(Designs::Repo::Diverged) { Designs::Threads.merge!(thread, user: @user) }
      assert thread.reload.open?
    end
  end


  test "a re-import's thread can be neither merged nor talked to while the import runs" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = thread_with_work(repo, "Re-import from staging", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      repo.project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: @user, design_thread: thread)

      assert_raises(Designs::Threads::Busy) { Designs::Threads.merge!(thread, user: @user) }
      assert_raises(Designs::Threads::Busy) { Designs::Threads.message!(thread, user: @user, text: "Trim it") }
    end
  end

  test "deleting a thread moves its branch to archive/ on GitHub, drops it here with its preview, and keeps the thread" do
    with_threads_remote do |repo, remote|
      master = seed_master(repo)
      thread = thread_with_work(repo, "Stage colours on pipeline", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      work = repo.head(thread.branch)
      Designs::Threads.publish(thread)
      preview = Pathname(@preview_root).join(repo.project.reload.design_preview_token, thread.branch)
      assert preview.exist?

      freeze_time do
        Designs::Threads.delete!(thread, user: @user)

        assert_nil remote_branch_sha(remote, thread.branch)
        assert_equal work, remote_branch_sha(remote, "archive/#{thread.branch}")
        assert_nil repo.head(thread.branch)
        assert_not repo.worktree_path(thread.branch).exist?
        assert_not preview.exist?
        thread.reload
        assert_equal [ "deleted", Time.current ], [ thread.status, thread.deleted_at ]
        assert_equal 20, thread.days_left
        assert ChatSession.exists?(thread.chat_session_id)
        assert_includes system_lines(thread), "Deleted by #{@user.name} · #{thread.branch} kept as archive/#{thread.branch} for 20 days"
        assert_equal master, remote_branch_sha(remote, "master")
      end
    end
  end

  test "a deleted thread comes back with its branch, its task and its preview" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1051", external_type: "jira")
      thread = Designs::Threads.start_from_task!(task, user: @user)
      commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      repo.push!(thread.branch)
      DesignTurn.update_all(status: "succeeded")
      work = repo.head(thread.branch)
      Designs::Threads.delete!(thread, user: @user)
      assert_nil task.reload.design_thread

      Designs::Threads.restore!(thread.reload, user: @user)

      assert_equal work, remote_branch_sha(remote, thread.branch)
      assert_nil remote_branch_sha(remote, "archive/#{thread.branch}")
      assert_equal work, repo.head(thread.branch)
      thread.reload
      assert_equal [ "open", nil, task ], [ thread.status, thread.deleted_at, thread.task ]
      assert Pathname(@preview_root).join(repo.project.reload.design_preview_token, thread.branch).exist?
      assert_equal "Restored by #{@user.name} from archive/#{thread.branch}", system_lines(thread).last
    end
  end

  test "a deleted thread whose task has another thread by now comes back without the task" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "SP-1051", external_type: "jira")
      thread = Designs::Threads.start_from_task!(task, user: @user)
      commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      repo.push!(thread.branch)
      DesignTurn.update_all(status: "succeeded")
      Designs::Threads.delete!(thread, user: @user)
      newer = Designs::Threads.start_from_task!(task.reload, user: @user)

      Designs::Threads.restore!(thread.reload, user: @user)

      assert_nil thread.reload.task
      assert_equal newer, task.reload.design_thread
    end
  end

  test "a thread deleted 20 days ago goes for good: its archive branch and its conversation" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      old = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      recent = thread_with_work(repo, "Bulk move", { "designs/admin/bulk.html" => "<title>Bulk</title>" })
      travel_to(21.days.ago) { Designs::Threads.delete!(old, user: @user) }
      travel_to(19.days.ago) { Designs::Threads.delete!(recent, user: @user) }

      Designs::PurgeDeletedThreadsJob.perform_now

      assert_nil remote_branch_sha(remote, "archive/#{old.branch}")
      assert_not DesignThread.exists?(old.id)
      assert_not ChatSession.exists?(old.chat_session_id)
      assert remote_branch_sha(remote, "archive/#{recent.branch}")
      assert DesignThread.exists?(recent.id)
    end
  end

  test "an empty thread, which has no branch yet, is deleted without the design repo" do
    thread = Designs::Threads.start!(project: projects(:jira_project), user: @user)

    Designs::Threads.delete!(thread)

    assert_not DesignThread.exists?(thread.id)
  end

  test "a thread is not deleted while Flosis AI works in it or a re-import runs on it" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      Designs::Threads.message!(thread, user: @user, text: "And a legend")
      assert_raises(Designs::Threads::Busy) { Designs::Threads.delete!(thread) }

      DesignTurn.update_all(status: "succeeded")
      repo.project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: @user, design_thread: thread)
      assert_raises(Designs::Threads::Busy) { Designs::Threads.delete!(thread) }

      assert DesignThread.exists?(thread.id)
      assert remote_branch_sha(remote, thread.branch)
    end
  end

  test "a branch GitHub refuses to move keeps the thread whole" do
    with_threads_remote do |repo, remote|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      hook = File.join(remote, "hooks", "pre-receive")
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)

      assert_raises(GitRunner::Error) { Designs::Threads.delete!(thread, user: @user) }

      assert thread.reload.open?
      assert remote_branch_sha(remote, thread.branch)
      assert_nil remote_branch_sha(remote, "archive/#{thread.branch}")
      assert repo.head(thread.branch)
      assert repo.worktree_path(thread.branch).exist?
    end
  end

  test "a merged thread is never deleted" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      Designs::Threads.merge!(thread, user: @user)

      assert_raises(Designs::Threads::AlreadyMerged) { Designs::Threads.delete!(thread) }
      assert DesignThread.exists?(thread.id)
    end
  end

  test "Try again runs the request of the turn that failed once more, as a new turn of its kind" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      failed = Designs::Threads.message!(thread, user: @user, text: "Add a status filter")
      failed.update!(status: "failed", error: "Claude returned no answer", started_at: 2.minutes.ago, kind: "resolve_conflicts")
      clear_enqueued_jobs

      turn = Designs::Threads.retry!(thread.reload, user: @user)

      assert_equal [ failed.chat_message_id, "resolve_conflicts", "queued" ], [ turn.chat_message_id, turn.kind, turn.status ]
      assert_not_equal failed.id, turn.id, "the failed turn keeps what it did"
      assert_enqueued_with(job: Designs::TurnJob, args: [ turn.id ])
      assert_equal "Tried again by #{@user.name}", system_lines(thread).last
    end
  end

  test "Try again needs the thread's last turn to have failed, and nothing running" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      assert_raises(ArgumentError) { Designs::Threads.retry!(thread, user: @user) }
      turn = Designs::Threads.message!(thread, user: @user, text: "Add a status filter")
      assert_raises(Designs::Threads::Busy) { Designs::Threads.retry!(thread.reload, user: @user) }
      turn.update!(status: "succeeded")
      assert_raises(ArgumentError) { Designs::Threads.retry!(thread, user: @user) }
      assert_equal 1, DesignTurn.where(chat_session: thread.chat_session).count
    end
  end

  test "Stop on a turn that waits fails it at once, so it never starts" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      turn = Designs::Threads.message!(thread, user: @user, text: "Add a status filter")

      Designs::Threads.stop!(thread.reload, turn_id: turn.id, user: @user)

      assert turn.reload.failed?
      assert_equal "Stopped by #{@user.name} before it started.", turn.error
      assert_equal [ "error", turn.error ], thread.chat_session.chat_messages.order(:id).pluck(:kind, :content).last
    end
  end

  test "Stop on a turn that runs asks its job to stop it, once" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      turn = Designs::Threads.message!(thread, user: @user, text: "Add a status filter")
      turn.update!(status: "running", started_at: 1.minute.ago)

      Designs::Threads.stop!(thread.reload, turn_id: turn.id, user: @user)

      assert turn.reload.running?, "its job stops it, and puts the worktree back"
      assert_equal @user.name, turn.stop_requested_by
      asked = turn.stop_requested_at
      travel(5.seconds) { Designs::Threads.stop!(thread, turn_id: turn.id, user: users(:two)) }
      assert_equal [ asked, @user.name ], [ turn.reload.stop_requested_at, turn.stop_requested_by ]
    end
  end

  test "Stop leaves a finished turn as it is, and reaches no other thread's turn" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = Designs::Threads.start!(project: repo.project, user: @user)
      turn = Designs::Threads.message!(thread, user: @user, text: "Add a status filter")
      turn.update!(status: "succeeded")
      other = Designs::Threads.start!(project: repo.project, user: @user)
      elsewhere = Designs::Threads.message!(other, user: @user, text: "Add a date filter")

      Designs::Threads.stop!(thread.reload, turn_id: turn.id, user: @user)

      assert turn.reload.succeeded?
      assert_nil turn.stop_requested_at
      assert_raises(ActiveRecord::RecordNotFound) { Designs::Threads.stop!(thread, turn_id: elsewhere.id, user: @user) }
      assert elsewhere.reload.queued?
    end
  end

  # -- components before a merge (2026-11-10: a design turn builds screens only) --

  def with_committed_turns(thread)
    DesignTurn.where(chat_session: thread.chat_session).update_all(commit_sha: "abc1234")
    thread
  end

  test "Merge makes components first when design turns committed since: a components turn, which merges once it is done" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = with_committed_turns(thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" }))
      clear_enqueued_jobs

      turn = Designs::Threads.merge_or_prepare!(thread, user: @user)

      assert_equal [ "components", "manual", "queued" ], [ turn.kind, turn.then_merge, turn.status ]
      assert_equal "request", turn.chat_message.kind
      assert_includes turn.chat_message.content, Designs::Threads::COMPONENTS_REQUEST
      assert_includes turn.chat_message.content, "The screens this thread changed:\n- designs/admin/pipeline.html"
      assert_enqueued_with(job: Designs::TurnJob, args: [ turn.id ])
      assert_equal "Making components from this thread's screens before it merges · #{@user.name}", system_lines(thread).last
      assert_not thread.reload.merged?
    end
  end

  test "Merge goes straight to master when no design turn committed since the components turn, or none ever did" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" })
      assert_kind_of DesignMerge, Designs::Threads.merge_or_prepare!(thread, user: @user), "no turn of it committed"

      other = with_committed_turns(thread_with_work(repo, "Closing dates", { "designs/candidate/apps.html" => "<title>Apps</title>" }))
      DesignTurn.create!(chat_session: other.chat_session, chat_message: other.chat_session.chat_messages.first, kind: "components",
                         status: "succeeded")
      assert_not Designs::Threads.components_due?(other)
      assert_kind_of DesignMerge, Designs::Threads.merge_or_prepare!(other.reload, user: @user)
    end
  end

  test "Try again on a components turn that failed merges when it succeeds, as the first one would have" do
    with_threads_remote do |repo, _|
      seed_master(repo)
      thread = with_committed_turns(thread_with_work(repo, "Stage colours", { "designs/admin/pipeline.html" => "<title>Pipeline</title>" }))
      Designs::Threads.merge_or_prepare!(thread, user: @user).update!(status: "failed", error: "Claude returned no answer", started_at: 1.minute.ago)

      turn = Designs::Threads.retry!(thread.reload, user: @user)

      assert_equal [ "components", "manual" ], [ turn.kind, turn.then_merge ]
    end
  end
end
