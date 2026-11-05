require "test_helper"

# The Designs module (Workshop Designs v2), against the copy of Kacper's
# ClearBacklog-3.html and the approved master-changed mockup.
class Workshop::DesignsModuleControllerTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  SCREEN = ->(title, body = "") { "<html><head><title>#{title}</title></head><body><h1>#{title}</h1>#{body}</body></html>" }

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
        seed_master(repo, { "designs/candidate/apply.html" => SCREEN.("Application form"),
                            "designs/recruiter/pipeline.html" => SCREEN.("Pipeline"),
                            "design-system/theme.css" => "@theme { --color-primary: #1779ba; --radius-card: 4px; }",
                            "components/button/button.html" => "<button>{{label}}</button>" })
        @project.reload.update!(design_repo_status: "ready")
        Designs::Publisher.new(@project, repo).publish!("master", "master")
        yield repo
      end
    end
  end

  # A thread with one turn's worth of work on its branch, published.
  def thread_with_work(repo, text = "Add a counter", files = { "designs/candidate/apply.html" => SCREEN.("Application form", "<p>121 / 500</p>") }, task: nil)
    thread = task ? Designs::Threads.start_from_task!(task, user: users(:one)) : Designs::Threads.start!(project: @project, user: users(:one))
    Designs::Threads.message!(thread, user: users(:one), text: text) unless task
    thread.reload
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), files)
    repo.push!(thread.branch)
    DesignTurn.update_all(status: "succeeded")
    Designs::Publisher.new(@project, repo).publish!(thread.branch, thread.branch, base: thread.base_sha)
    thread
  end

  test "the sidebar has Designs for whoever holds the Designs permission" do
    with_designs do
      get workshop_pipeline_path
      assert_select "a[href=?]", workshop_designs_overview_path, text: /Designs/
    end
  end

  test "the list shows master read-only, the library and New thread, and the canvas shows master's screen" do
    with_designs do
      get workshop_designs_overview_path
      assert_response :success
      %w[Designs Hide\ menus Design\ system Components Merge\ history BRANCHES\ ·\ 1 master Read-only No\ open\ threads.
         New\ thread View\ as Candidate Recruiter Read-only\ ·\ start\ a\ thread\ to\ change\ it Open\ in\ new\ tab].each do |copy|
        assert_includes response.body, CGI.escapeHTML(copy), copy
      end
      frame = css_select("iframe[data-designs-canvas-target=frame]").sole
      assert_equal "allow-scripts allow-forms allow-popups allow-modals", frame["sandbox"]
      assert_match %r{/design/designs/candidate/apply\.html\z}, frame["src"]
      assert_select ".clar-seg-item[title=?]", "Not available for Recruiter"
    end
  end

  test "a thread shows its branch, how far ahead it is, its modes, and its dialogs" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      get workshop_designs_overview_path(thread: thread.id)
      assert_response :success
      [ thread.branch, "1 commits ahead", "Generate task", "Generate a task when the scope is clear. It starts in Details Gathering.",
        "This branch", "Master", "Changes", "Merge to master", "Describe a change…", "AI sees Candidate › Application form",
        "Merge into master?", "This thread has no task, so it only merges when you merge it.",
        "After merging, master stays read-only and further changes need a new thread.",
        "Create task · start Details Gathering", "Linked to #{thread.branch}. The thread merges into master when the task is Done.",
        "Scope, from design thread #{thread.branch}:" ].each do |copy|
        assert_includes response.body, CGI.escapeHTML(copy), copy
      end
    end
  end

  test "Changes shows the screen marked up against the thread's base, and lists the changed screens" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      get workshop_designs_overview_path(thread: thread.id, mode: "changes")
      assert_includes response.body, "Changed in this thread"
      assert_match %r{designs/candidate/apply\.changes\.html\z}, css_select("iframe[data-designs-canvas-target=frame]").sole["src"]
    end
  end

  test "an empty thread says it has no changes yet and asks what should change" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "No changes yet"
      assert_includes response.body, CGI.escapeHTML("What should change? Navigate the app on the right, AI sees the page you’re on.")
    end
  end

  test "a thread's row and banners say when its task or master changed" do
    with_designs do |repo|
      task = tasks(:jira_task)
      task.update!(project: @project, external_reference: "SP-1051", external_type: "jira", description: "Validate on blur")
      waiting = thread_with_work(repo, "x", { "designs/candidate/apply.html" => SCREEN.("Application form", "<em>mine</em>") }, task: task)
      other = thread_with_work(repo, "Stage colours on pipeline", { "designs/recruiter/pipeline.html" => SCREEN.("Pipeline", "<b>stages</b>") })
      Designs::Threads.merge!(other, user: users(:one))
      task.update!(description: "Validate on blur\nShow a counter")

      get workshop_designs_overview_path
      assert_includes response.body, "Task changed"
      assert_includes response.body, "Master changed"

      get workshop_designs_overview_path(thread: waiting.id)
      assert_includes response.body, "SP-1051 changed"
      assert_includes response.body, "since the last design update"
      assert_includes response.body, "master changed"
      assert_includes response.body, "since this thread branched"
      assert_includes response.body, "Update from master"
      assert_includes response.body, "Stage colours on pipeline"
      assert_includes response.body, "1 merge behind master"
      assert_includes response.body, "Merges automatically when SP-1051 moves to Done."
      assert_includes response.body, "Update from master first to see the result before it lands."
    end
  end

  test "the library pages show master's tokens, components and merges" do
    with_designs do |repo|
      get workshop_designs_overview_path(tab: "system")
      assert_includes response.body, "#1779ba"
      assert_includes response.body, "design-system/theme.css"
      assert_includes response.body, "Token changes go through threads like any other design change."

      get workshop_designs_overview_path(tab: "components")
      assert_includes response.body, "components/button/button.html"
      assert_includes response.body, "Used in 0 of 2 context views"

      Designs::Threads.merge!(thread_with_work(repo), user: users(:one))
      get workshop_designs_overview_path(tab: "history")
      assert_includes response.body, "Threads merged into master, newest first. Click a merge to see what went in."
      assert_includes response.body, "Manual · #{users(:one).name}"
      assert_includes response.body, "SUMMARY"
    end
  end

  test "the settings drawer says what the repo holds and where the designs came from" do
    with_designs do
      get workshop_designs_overview_path
      [ "Design settings", "Changing these needs the Configuration permission.", "REPOSITORY", "STACK", "STRUCTURE",
        "INITIAL SOURCES", "acme/designs", "HTML + CSS", "inspirations/" ].each do |copy|
        assert_includes response.body, CGI.escapeHTML(copy), copy
      end
    end
  end

  test "people outside Flosis staff do not see Designs until it is switched on for the project" do
    @project.update!(designs_enabled: false)
    users(:one).update!(flosis_staff: false)
    get workshop_designs_overview_path
    assert_response :not_found
  end

  test "a thread with nothing of its own yet offers no merge" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Errors under the field")
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "0 commits ahead"
      assert_not_includes response.body, "Merge to master"
    end
  end


  test "the design system page shows only colour values, never anything else a theme might hold" do
    with_designs do |repo|
      dir = repo.root
      commit_files(repo, dir, { "design-system/theme.css" => "@theme { --color-primary: #1779ba; --color-evil: url(https://evil.test/x); --color-mix: rgb(1 2 3); }" })
      repo.push!("master")
      Designs::Publisher.new(@project, repo).publish!("master", "master")

      get workshop_designs_overview_path(tab: "system")
      assert_includes response.body, "background: #1779ba"
      assert_includes response.body, "background: rgb(1 2 3)"
      assert_not_includes response.body, "background: url("
    end
  end


  test "a thread of a local task merges by hand, and its merge dialog says so" do
    with_designs do |repo|
      task = @project.tasks.create!(name: "Local idea")
      task.enter_pipeline!(author: users(:one), stage: "briefing")
      thread = thread_with_work(repo, "x", { "designs/candidate/apply.html" => SCREEN.("Application form", "<em>1</em>") }, task: task)
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "This thread merges when you merge it."
      assert_not_includes response.body, "This thread has no task"
    end
  end

  test "Designs opened from a task leads back to it" do
    with_designs do
      task = tasks(:jira_task)
      task.update!(project: @project, external_reference: "SP-1051")
      task.enter_pipeline!(author: users(:one), stage: "briefing")
      get workshop_designs_overview_path(back: task.id)
      assert_select "a[href=?]", workshop_idea_path(task), text: /Back to SP-1051 · #{Regexp.escape(task.name)}/
    end
  end

  test "each open thread's row offers Delete, which asks first" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      fresh = Designs::Threads.start!(project: @project, user: users(:one))

      get workshop_designs_overview_path
      form = css_select("form[action='#{workshop_design_thread_path(thread)}']").sole
      assert_equal %(Delete "Add a counter" and its branch design/add-a-counter? What it has not merged into master is lost.),
                   form["data-turbo-confirm"]
      assert_select form, "input[name=_method][value=delete]"
      assert_select form, "button[title=?]", "Delete thread"
      assert_equal %(Delete "New thread"?), css_select("form[action='#{workshop_design_thread_path(fresh)}']").sole["data-turbo-confirm"]
    end
  end

end
