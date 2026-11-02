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
        yield repo
      end
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
end
