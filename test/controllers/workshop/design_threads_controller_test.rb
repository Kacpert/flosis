require "test_helper"

class Workshop::DesignThreadsControllerTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  def with_designs
    with_design_remote(@project) do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo, { "designs/candidate/apply.html" => "<title>Application form</title><h1>Apply</h1>" })
        @project.reload.update!(design_repo_status: "ready")
        yield repo, remote
      end
    end
  end

  # A thread with a commit of its own on its branch, pushed, as a turn leaves it.
  def thread_with_work(repo, text)
    thread = Designs::Threads.start!(project: @project, user: users(:one))
    Designs::Threads.message!(thread, user: users(:one), text: text)
    thread.reload
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), { "designs/candidate/apply.html" => "<title>Application form</title><p>1</p>" })
    repo.push!(thread.branch)
    # The first message plans (2026-11-21), and the plan goes on to design.
    Designs::Threads.design_as_planned!(thread, user: users(:one))
    DesignTurn.update_all(status: "succeeded")
    thread
  end

  test "Delete puts the thread under Deleted, its branch in the archive, and goes back to the threads" do
    with_designs do |repo, remote|
      thread = thread_with_work(repo, "Add a counter")

      delete workshop_design_thread_path(thread)
      assert_redirected_to workshop_designs_overview_path
      assert_equal "Thread deleted · you can restore it for 20 days", flash[:clar_toast]
      assert thread.reload.deleted?
      assert_nil remote_branch_sha(remote, "design/add-a-counter")
      assert remote_branch_sha(remote, "archive/design/add-a-counter")
    end
  end

  test "Restore brings a deleted thread back and opens it" do
    with_designs do |repo, remote|
      thread = thread_with_work(repo, "Add a counter")
      Designs::Threads.delete!(thread, user: users(:one))

      post restore_workshop_design_thread_path(thread)
      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal "Thread restored · design/add-a-counter", flash[:clar_toast]
      assert thread.reload.open?
      assert remote_branch_sha(remote, "design/add-a-counter")
    end
  end

  test "a deleted thread takes no message and opens as the threads list" do
    with_designs do |repo|
      thread = thread_with_work(repo, "Add a counter")
      Designs::Threads.delete!(thread, user: users(:one))

      post message_workshop_design_thread_path(thread), params: { text: "One more thing" }
      assert_response :not_found
      get workshop_designs_overview_path(thread: thread.id)
      assert_response :success
      assert_includes response.body, "BRANCHES"
      assert_select "textarea[name=text]", count: 0
    end
  end

  test "Delete takes an empty thread at once" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))

      delete workshop_design_thread_path(thread)
      assert_redirected_to workshop_designs_overview_path
      assert_equal "Thread deleted", flash[:clar_toast]
      assert_not DesignThread.exists?(thread.id)
    end
  end

  test "Delete waits while Flosis AI works in the thread" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")

      assert_no_difference -> { DesignThread.count } do
        delete workshop_design_thread_path(thread)
      end
      assert_redirected_to workshop_designs_overview_path
      assert_equal Designs::Threads::BUSY, flash[:alert]
    end
  end

  test "Delete keeps the thread when GitHub refuses to move its branch, and says so" do
    with_designs do |repo, remote|
      thread = thread_with_work(repo, "Add a counter")
      hook = File.join(remote, "hooks", "pre-receive")
      File.write(hook, "#!/bin/sh\necho 'protected branch' >&2\nexit 1\n")
      File.chmod(0o755, hook)

      delete workshop_design_thread_path(thread)
      assert thread.reload.open?
      assert_redirected_to workshop_designs_overview_path
      assert_match(/\AThe branch could not be moved to the archive on GitHub, so the thread stays: /, flash[:alert])
    end
  end

  test "New thread opens an empty thread" do
    with_designs do
      assert_difference -> { DesignThread.count } do
        post workshop_design_threads_path
      end
      thread = DesignThread.last
      assert thread.fresh?
      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
    end
  end

  test "a message names a fresh thread, keeps the screen the person sees, and queues a turn" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      post message_workshop_design_thread_path(thread), params: { text: "Errors under the field", ctx: "candidate", screen: "apply" }

      thread.reload
      assert_equal "design/errors-under-the-field", thread.branch
      assert_equal [ "candidate", "apply" ], [ thread.focus_context, thread.focus_screen ]
      assert_enqueued_jobs 1, only: Designs::TurnJob
    end
  end

  test "merging lands the thread on master and opens the merge history" do
    with_designs do |repo|
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      thread.reload
      commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), { "designs/candidate/apply.html" => "<title>Application form</title><p>1</p>" })
      repo.push!(thread.branch)
      DesignTurn.update_all(status: "succeeded")

      post merge_workshop_design_thread_path(thread)
      merge = DesignMerge.last
      assert_redirected_to workshop_designs_overview_path(tab: "history", merge: merge.id)
      assert_equal "Merged into master · #{merge.short_sha}", flash[:clar_toast]
      assert thread.reload.merged?
    end
  end

  test "Generate task makes a task in Details Gathering from the thread, and links them" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Closing date reminders")

      post create_task_workshop_design_thread_path(thread), params: { title: "Closing-date reminders", description: "Goal: remind candidates" }

      task = thread.reload.task
      assert_equal [ "Closing-date reminders", "details", true ], [ task.name, task.workshop_stage, task.in_pipeline ]
      assert_equal "Goal: remind candidates", task.current_detail_draft.content
      assert_redirected_to workshop_idea_path(task)
      assert_equal "Task created · Closing-date reminders · Details Gathering", flash[:clar_toast]
      assert_equal "Task task-#{task.id} created from this thread · Details Gathering started",
                   thread.chat_session.chat_messages.where(kind: "system").ordered.last.content
    end
  end

  test "a Project Manager, who has no Designs permission by default, cannot merge a thread" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      workspace_memberships(:two_employee).update!(workspace_admin: false)
      project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Project Manager"))
      sign_in_as(users(:two))
      post switch_product_path, params: { product: "workshop" }
      post switch_workshop_project_path, params: { project_id: @project.id }

      post merge_workshop_design_thread_path(thread)
      assert_not DesignMerge.exists?
      get workshop_designs_overview_path
      assert_response :redirect
    end
  end

  test "nobody outside Flosis staff can act on threads while Designs is off for the project" do
    thread = DesignThread.create!(project: @project, author: users(:one), title: "x")
    @project.update!(designs_enabled: false)
    users(:one).update!(flosis_staff: false)

    assert_no_difference -> { DesignThread.count } do
      post workshop_design_threads_path
    end
    assert_response :not_found
    post message_workshop_design_thread_path(thread), params: { text: "Do it" }
    assert_response :not_found
    assert_no_enqueued_jobs only: Designs::TurnJob
  end


  test "merging a thread with nothing of its own says so instead of failing" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Nothing yet")
      DesignTurn.update_all(status: "succeeded")

      post merge_workshop_design_thread_path(thread)
      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal Designs::Threads::NOTHING_TO_MERGE, flash[:alert]
    end
  end


  # Kacper (2026-11-19): an image goes with the message, as in the task chat,
  # and never into the repo's inspirations/.
  test "an image sent with a message is kept on it and nothing goes to inspirations/" do
    with_designs do |repo|
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Errors under the field").update!(status: "succeeded")

      post message_workshop_design_thread_path(thread),
           params: { text: "Like this", images: [ fixture_file_upload("inspiration.png", "image/png") ] }

      message = thread.chat_session.chat_messages.where(role: "user", kind: nil).ordered.last
      assert_equal "Like this", message.content
      assert_equal [ "inspiration.png" ], message.images.map { |image| image.filename.to_s }
      assert_equal message, DesignTurn.order(:id).last.chat_message
      assert_empty repo.ls_files(thread.reload.branch, "inspirations/")
    end
  end

  test "a file that is not an image is refused, and the message is not sent" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Errors under the field").update!(status: "succeeded")

      assert_no_difference -> { DesignTurn.count } do
        post message_workshop_design_thread_path(thread),
             params: { text: "Like this", images: [ Rack::Test::UploadedFile.new(StringIO.new("#!/bin/sh"), "text/x-sh", original_filename: "run.sh") ] }
      end
      assert_match(/run.sh is not a PNG, JPG, GIF or WebP image/, flash[:alert])
    end
  end

  # Kacper (2026-11-19): after sending, the canvas went back to This branch;
  # it stays on the mode and screen the person was looking at.
  test "a message keeps the canvas where it was" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a status filter").update!(status: "succeeded")

      post message_workshop_design_thread_path(thread), params: { text: "And a count", ctx: "candidate", screen: "apply", mode: "changes" }

      assert_redirected_to workshop_designs_overview_path(thread: thread.id, ctx: "candidate", screen: "apply", mode: "changes")
    end
  end

  test "Try again runs the failed turn's request once more" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a status filter")
      turn.update!(status: "failed", error: "Claude returned no answer", started_at: 1.minute.ago)

      assert_difference -> { DesignTurn.where(chat_message: turn.chat_message).count } do
        post retry_workshop_design_thread_path(thread)
      end

      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert DesignTurn.order(:id).last.queued?
    end
  end

  test "Design with these proposals starts the design and goes back to the thread" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a status filter").update!(kind: "plan", status: "succeeded")

      post go_workshop_design_thread_path(thread)

      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      last = DesignTurn.order(:id).last
      assert_equal "design", last.kind
      assert last.queued?
    end
  end

  test "Try again with nothing to try says so" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a status filter").update!(status: "succeeded")

      post retry_workshop_design_thread_path(thread)

      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal Designs::Threads::NOTHING_TO_RETRY, flash[:alert]
    end
  end

  test "Stop asks the job of a running turn to stop it" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a status filter")
      turn.update!(status: "running", started_at: 1.minute.ago)

      post stop_workshop_design_thread_path(thread), params: { turn: turn.id }

      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal users(:one).name, turn.reload.stop_requested_by
    end
  end

  test "Merge during the check after a build says it merges once the check is done" do
    with_designs do |repo, _|
      thread = thread_with_work(repo, "Add a counter")
      design = DesignTurn.where(chat_session: thread.chat_session, kind: "design").last
      Designs::Threads.new_check(thread, after: design, summary: "Added a counter.", chips: [ [ "apply", "candidate", "M" ] ])

      post merge_workshop_design_thread_path(thread)

      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal "Checking on screen first · it merges when that's done", flash[:clar_toast]
      assert_not thread.reload.merged?
    end
  end

  test "Merge makes components first when the thread's turns made screens since, and says it merges after" do
    with_designs do |repo, _|
      thread = thread_with_work(repo, "Add a counter")
      DesignTurn.where(chat_session: thread.chat_session).update_all(commit_sha: "abc1234")

      post merge_workshop_design_thread_path(thread)

      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal "Making components first · it merges when they're done", flash[:clar_toast]
      turn = DesignTurn.order(:id).last
      assert_equal [ "components", "manual" ], [ turn.kind, turn.then_merge ]
      assert_not thread.reload.merged?
    end
  end
end
