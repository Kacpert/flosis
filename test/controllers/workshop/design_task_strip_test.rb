require "test_helper"

# The Designs strip on a task's page and the badge on its pipeline row
# (Workshop Designs v2), against ClearBacklog-3.html and the master-changed
# mockup.
class Workshop::DesignTaskStripTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @task = tasks(:jira_task)
    @task.update!(project: @project, external_reference: "SP-1051", external_type: "jira", description: "Validate on blur")
    @task.enter_pipeline!(author: users(:one), stage: "briefing")
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

  test "a task with no thread offers Design with AI, which starts its thread and opens it" do
    with_designs do
      get workshop_idea_path(@task)
      assert_select "button", text: /Design with AI/
      assert_select "[data-task-header-top] a", text: /All tasks/
      assert_select "[data-task-header-top] button", text: /Design with AI/

      post workshop_start_idea_design_thread_path(@task)
      thread = @task.reload.design_thread
      assert_equal "design/SP-1051-#{@task.name.parameterize.split('-').first(4).join('-')}", thread.branch
      assert_redirected_to workshop_designs_overview_path(thread: thread.id)
      assert_equal "Design thread started · #{thread.branch}", flash[:clar_toast]
    end
  end

  test "Design with AI on a project without designs sends the person to set them up" do
    @project.update!(designs_enabled: true, design_repo_status: nil)
    post workshop_start_idea_design_thread_path(@task)
    assert_redirected_to workshop_designs_overview_path
    assert_equal "Set up Designs for #{@project.name} first", flash[:clar_toast]
  end

  test "the strip and the badge say when the description changed, and open the thread" do
    with_designs do
      thread = Designs::Threads.start_from_task!(@task, user: users(:one))
      @task.update!(description: "Validate on blur\nShow a counter")

      get workshop_idea_path(@task)
      [ thread.branch, "Description changed since the last design update", "Update designs from diff", "Open in Designs" ].each do |copy|
        assert_includes response.body, copy, copy
      end
      # Every thread merges by hand (2026-11-14): nothing says it merges on Done.
      assert_not_includes response.body, "merges on Done"

      get workshop_pipeline_path
      assert_includes response.body, "Designs need update"
    end
  end

  test "a merged thread says so on the task and in the pipeline" do
    with_designs do |repo|
      thread = Designs::Threads.start_from_task!(@task, user: users(:one))
      commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), { "designs/candidate/apply.html" => "<title>Application form</title><p>1</p>" })
      repo.push!(thread.branch)
      DesignTurn.update_all(status: "succeeded")
      merge = Designs::Threads.merge!(thread, user: users(:one))

      get workshop_idea_path(@task)
      # A task's merge is its designs' acceptance (2026-11-21).
      assert_includes response.body, "Accepted · #{merge.short_sha}"
      get workshop_pipeline_path
      assert_includes response.body, "Designs merged"
    end
  end

  test "a Jira task taken out of Create Tasks leaves its thread with no task" do
    thread = DesignThread.create!(project: @project, task: @task, author: users(:one), title: "x", branch: "design/SP-1051-x")
    delete workshop_idea_path(@task)
    assert_nil thread.reload.task_id
  end

  # Accept designs (2026-11-21): an accepted thread's strip opens its designs in
  # a new tab; a reopened one keeps a link to what was accepted.
  def accepted_thread(repo)
    thread = Designs::Threads.start_from_task!(@task, user: users(:one))
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), { "designs/candidate/apply.html" => "<title>Application form</title><p>1</p>" })
    repo.push!(thread.branch)
    DesignTurn.update_all(status: "succeeded")
    [ thread, Designs::Threads.merge!(thread.reload, user: users(:one)) ]
  end

  test "an accepted thread's strip opens the designs in a new tab" do
    with_designs do |repo|
      _, merge = accepted_thread(repo)
      get workshop_idea_path(@task)

      assert_select "[data-task-header-top]" do
        assert_select "*", text: /Accepted · #{merge.short_sha}/
        assert_select "a[target=_blank][href=?]", Designs::Publisher.new(@project, nil).url("SP-1051", nil), text: /Open designs/
        assert_select "a", text: /Open in Designs/
      end
    end
  end

  test "a reopened thread's strip links the accepted version" do
    with_designs do |repo|
      thread, merge = accepted_thread(repo)
      # The describe turn has written the description by now.
      DesignTurn.where(kind: "describe").update_all(status: "succeeded")
      Designs::Threads.reopen!(thread.reload, user: users(:one))
      get workshop_idea_path(@task)

      assert_select "[data-task-header-top]" do
        assert_select "*", text: thread.branch
        assert_select "a[target=_blank][href=?]", Designs::Publisher.new(@project, nil).url("SP-1051", nil), text: /Accepted · #{merge.short_sha}/
      end
    end
  end
end
