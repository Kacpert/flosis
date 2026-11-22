require "test_helper"

# Designs imports: the Imports line in the Designs list, the list of imports,
# and an import's page (after the mockups import-page.html, imports-link.html
# and review-card.html beside the design), which stays after the import ends.
class Workshop::DesignImportsPagesTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  LIMIT = "Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)".freeze
  SCREEN = ->(title) { "<html><head><title>#{title}</title></head><body><h1>#{title}</h1></body></html>" }

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(design_app_url: "https://app.flosis.com", designs_enabled: true)
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
        seed_master(repo, { "designs/admin/bugs.html" => SCREEN.("Bug Reporting"), "design-system/theme.css" => "@theme { --color-primary: #5b5bd6; }" })
        @project.reload.update!(design_repo_status: "ready")
        Designs::Publisher.new(@project, repo).publish!("master", "master")
        yield repo
      end
    end
  end

  # The first import as it ended on Nov 3: features as [name, status, more].
  def first_import(features = [])
    finished = Time.zone.local(2026, 11, 3, 6, 50)
    setup = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one),
                                           created_at: Time.zone.local(2026, 11, 3, 1, 40), finished_at: finished, settled_at: finished)
    features.each_with_index do |(name, status, more), i|
      setup.features.create!(name: name, key: name.parameterize, position: i + 1, status: status, contexts: %w[1-admin], **(more || {}))
    end
    setup
  end

  def imports_line
    css_select("a[data-imports-line]").first
  end

  test "the Imports line is lit after an import settles, until its page is opened" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done" ] ])
      get workshop_designs_overview_path
      assert_equal "true", imports_line["data-lit"]
      assert_equal workshop_designs_overview_path(tab: "imports"), imports_line["href"]

      get workshop_designs_overview_path(tab: "imports", import: import.id)
      assert_response :success
      get workshop_designs_overview_path
      assert_equal "false", imports_line["data-lit"]
    end
  end

  test "the line says N need you while cards wait, else the date of the last import" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done" ], [ "Task workspace", "failed", { error: "Failed to parse Claude response" } ] ])
      get workshop_designs_overview_path
      assert_includes imports_line.text.squish, "1 need you"

      import.features.find_by!(name: "Task workspace").update!(status: "set_aside")
      get workshop_designs_overview_path
      assert_includes imports_line.text.squish, "Nov 3"
      assert_not_includes imports_line.text, "need you"
    end
  end

  test "Imports lists every import newest first with what each built" do
    with_designs do
      first_import([ [ "App shell", "done" ], [ "Reporting", "done" ], [ "Designs", "failed", { error: LIMIT } ] ])
      thread = @project.design_threads.create!(title: "Re-import from staging", author: users(:one))
      @project.design_setups.create!(kind: "reimport", status: "active", phase: "map", step: 0, started_by: users(:one), design_thread: thread)

      get workshop_designs_overview_path(tab: "imports")
      assert_response :success
      titles = css_select("[data-import-entry] [data-import-title]").map { _1.text.squish }
      assert_equal [ "Re-import from staging", "First import · from app.flosis.com" ], titles
      assert_includes response.body, "2 of 3 features built"
      assert_includes response.body, "1 need you"
    end
  end

  test "an import's page explains each card" do
    with_designs do
      import = first_import([
        [ "Task workspace", "failed", { error: "Failed to parse Claude response", finished_at: Time.zone.local(2026, 11, 3, 4, 0) } ],
        [ "Designs", "failed", { error: LIMIT, finished_at: Time.zone.local(2026, 11, 3, 6, 50) } ],
        [ "Jira Tasks board", "waiting", { question: "The Jira board was empty for every context. Connect Jira on the test project and tell me to go on." } ],
        [ "Profile", "failed", { error: "Claude stopped with an error: overloaded" } ]
      ])
      get workshop_designs_overview_path(tab: "imports", import: import.id)
      assert_response :success
      body = CGI.unescapeHTML(response.body)
      assert_includes body, "First import · from app.flosis.com"
      assert_includes body, "0 of 4 features built"
      assert_includes body, "4 need you"
      assert_includes body, "The AI's answer could not be read."
      assert_includes body, "Claude's session limit ran out at 06:50 (it resets at 08:00)."
      assert_includes body, "Waiting for you"
      assert_includes body, "The Jira board was empty for every context."
      assert_includes body, "Couldn't finish"
      assert_includes body, "Not started"
      assert_includes body, "overloaded"
      cards = css_select("[data-import-card]").map { _1["data-import-card"] }
      assert_equal %w[jira-tasks-board task-workspace profile designs], cards, "worst first: waiting, couldn't finish, then not started"
    end
  end

  test "Built lists each finished feature with its notes" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done", { notes: [ "No bugs in the test data." ], components_new: 3, components_reused: 2 } ] ])
      get workshop_designs_overview_path(tab: "imports", import: import.id)
      body = CGI.unescapeHTML(response.body)
      assert_includes body, "BUILT · 1"
      assert_includes body, "3 new, 2 reused"
      assert_includes body, "1 note"
      assert_includes body, "No bugs in the test data."
    end
  end

  test "someone without configuration sees the page but no actions" do
    with_designs do
      import = first_import([ [ "Task workspace", "failed", { error: "Failed to parse Claude response" } ] ])
      project_memberships(:two_elvium).update!(designs: true, configuration: false)
      sign_in_as(users(:two))
      post switch_product_path, params: { product: "workshop" }
      post switch_workshop_project_path, params: { project_id: @project.id }

      get workshop_designs_overview_path(tab: "imports", import: import.id)
      assert_response :success
      assert_includes CGI.unescapeHTML(response.body), "Couldn't finish"
      assert_select "form[action*='designs/imports']", false
    end
  end

  # Final review C2: a feature from before the imports existed has no review.
  test "a feature from before the imports existed can be set aside and its page still opens" do
    with_designs do
      import = first_import([ [ "Designs setup", "set_aside" ], [ "Profile", "failed", { error: "Failed to parse Claude response" } ] ])
      import.features.update_all(review: nil)
      get workshop_designs_overview_path(tab: "imports", import: import.id)
      assert_response :success
      assert_includes response.body, "Not needed"
    end
  end

  test "the setup page shows a first import that is still running" do
    @project.update!(design_repo_status: "pending")
    setup = @project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one))
    setup.features.create!(name: "App shell", key: "app-shell", position: 1, status: "done")
    setup.features.create!(name: "Task workspace", key: "task-workspace", position: 2, status: "failed", error: "Failed to parse Claude response")
    setup.features.create!(name: "Reporting", key: "reporting", position: 3, status: "running", stage: "building")

    get workshop_design_setup_run_path
    assert_response :success
    body = CGI.unescapeHTML(response.body)
    assert_includes body, "Building designs for #{@project.name}"
    assert_includes body, "Running in the background"
    assert_includes body, "NEEDS YOU · 1"
    assert_includes body, "The AI's answer could not be read."
  end

  test "the page says the run is paused until the limit resets" do
    @project.update!(design_repo_status: "pending")
    travel_to Time.zone.local(2026, 11, 4, 6, 55) do
      setup = @project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one),
                                             paused_until: Time.zone.local(2026, 11, 4, 8, 0))
      setup.features.create!(name: "Designs", key: "designs", position: 1, status: "todo", resets_at: Time.zone.local(2026, 11, 4, 8, 0),
                             error: "Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)")
      get workshop_design_setup_run_path
    end
    body = CGI.unescapeHTML(response.body)
    assert_includes body, "Paused until 08:00 · Claude's session limit ran out. The import goes on by itself."
    assert_includes body, "The import goes on by itself at 08:00."
  end

  test "a stopped import shows why, with Retry" do
    @project.update!(design_repo_status: "pending")
    stopped = @project.design_setups.create!(status: "failed", phase: "map", step: 2, started_by: users(:one), error: "The map found no features.")

    get workshop_design_setup_run_path
    assert_response :success
    assert_includes response.body, "The build stopped"
    assert_includes response.body, "The map found no features."
    assert_select "form[action=?]", retry_workshop_design_setup_run_path(import: stopped.id)
  end

  test "Designs stays open while a resync runs, and Imports offers a new one" do
    with_designs do
      first = first_import([ [ "Bug Reporting", "done" ] ])
      @project.design_setups.create!(kind: "resync", since_setup: first, status: "active", phase: "resync", step: 2, started_by: users(:one))
      get workshop_designs_overview_path(tab: "imports")
      assert_response :success
      assert_includes response.body, "Changes since Nov 3"
      assert_select "a[href=?]", new_workshop_design_import_path, false, "not while one runs"
    end
  end

  test "Imports offers a new import once the last one is over" do
    with_designs do
      first_import([ [ "Bug Reporting", "done" ] ])
      get workshop_designs_overview_path(tab: "imports")
      assert_select "a[href=?]", new_workshop_design_import_path, text: "New import"
    end
  end

  test "the master-ready notice leads to the import's page" do
    import = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), finished_at: Time.current)
    get workshop_pipeline_path
    assert_includes response.body, "Designs ready · #{@project.name} @ master"
    assert_select "[data-clar-toast-link-value=?]", workshop_designs_overview_path(tab: "imports", import: import.id)
  end

  test "Designs ready is told for the first import only" do
    first = @project.design_setups.create!(status: "approved", phase: "feature", step: 6, started_by: users(:one), finished_at: 1.hour.ago, notified_at: 1.hour.ago)
    @project.design_setups.create!(kind: "resync", since_setup: first, status: "approved", phase: "feature", step: 5, started_by: users(:one), finished_at: Time.current)
    get workshop_pipeline_path
    assert_not_includes response.body, "Designs ready"
  end

  # Final review C1 and M1.
  test "Designs never locks behind a first import that is over" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done" ] ])
      import.update!(status: "active")
      get workshop_designs_overview_path
      assert_response :success
    end
  end

  test "Retry on a stopped import's page retries that import" do
    with_designs do
      first = first_import([ [ "Bug Reporting", "done" ] ])
      stopped = @project.design_setups.create!(kind: "resync", since_setup: first, status: "failed", phase: "resync", step: 2, started_by: users(:one), error: "boom")
      newer = @project.design_setups.create!(kind: "resync", since_setup: first, status: "approved", phase: "feature", step: 5, started_by: users(:one), finished_at: Time.current)
      post retry_workshop_design_setup_run_path, params: { import: stopped.id }
      assert_equal [ "active", nil ], [ stopped.reload.status, stopped.error ]
      assert_equal "approved", newer.reload.status
      assert_enqueued_with(job: Designs::SetupRunJob, args: [ stopped.id ])
      assert_redirected_to workshop_designs_overview_path(tab: "imports", import: stopped.id)
    end
  end

  test "a stopped re-import whose thread was deleted is never retried, and says why" do
    with_designs do
      first_import([ [ "Bug Reporting", "done" ] ])
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      stopped = @project.design_setups.create!(kind: "reimport", status: "failed", phase: "feature", step: 4, started_by: users(:one),
                                               error: "boom", design_thread: thread)
      Designs::Threads.delete!(thread)

      get workshop_designs_overview_path(tab: "imports", import: stopped.id)
      assert_includes response.body, "boom"
      assert_includes response.body, DesignSetup::THREAD_DELETED
      assert_select "form[action=?]", retry_workshop_design_setup_run_path(import: stopped.id), count: 0

      post retry_workshop_design_setup_run_path, params: { import: stopped.id }
      assert_equal "failed", stopped.reload.status
      assert_no_enqueued_jobs only: Designs::SetupRunJob
      assert_redirected_to workshop_designs_overview_path(tab: "imports", import: stopped.id)
      assert_equal DesignSetup::THREAD_DELETED, flash[:alert]
    end
  end

  test "once master has the first import its page is in Designs" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done" ] ])
      get workshop_design_setup_run_path
      assert_redirected_to workshop_designs_overview_path(tab: "imports", import: import.id)
    end
  end

  include AiRunTestHelper

  # SCRUM-70: each import says what it cost, on the list and on its page.
  test "an import shows its AI cost when costs are on" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done" ] ])
      priced_runs!(import, area: "designs", total: 48.90, this_month: 48.90, project: @project)
      show_ai_costs!

      get workshop_designs_overview_path(tab: "imports")
      assert_includes response.body, "$48.90"
      get workshop_designs_overview_path(tab: "imports", import: import.id)
      assert_includes response.body, "$48.90"
    end
  end


  # SCRUM-70: the imports page says what Designs and its imports cost this month.
  test "the imports page shows what Designs and imports cost this month" do
    with_designs do
      first_import([ [ "Bug Reporting", "done" ] ])
      AiRun.create!(workspace: workspaces(:one), project: @project, area: "designs", automation: "Test", status: "succeeded",
                    ran_at: Time.current, cost_usd: 182.35, price_usd: 182.35)
      show_ai_costs!

      get workshop_designs_overview_path(tab: "imports")
      assert_includes response.body, "Designs and imports · #{Date.current.strftime('%B %Y')} · $182.35 · 1 run"
    end
  end

  # Kacper, 2026-11-22: a running import can be stopped from its page; a
  # stopped one says who stopped it, and can be resumed.
  test "a running import shows Stop, a stopped one says who stopped it" do
    with_designs do
      since = first_import([ [ "App shell", "done" ] ])
      running = @project.design_setups.create!(kind: "resync", since_setup: since, status: "active", phase: "feature", step: 3, started_by: users(:one))

      get workshop_designs_overview_path(tab: "imports", import: running.id)
      assert_select "form[action='#{stop_workshop_design_import_path(running)}'] button", text: "Stop"

      running.update!(status: "failed", stopped_at: Time.zone.local(2026, 11, 22, 2, 47), stopped_by: users(:one))
      get workshop_designs_overview_path(tab: "imports", import: running.id)
      assert_includes CGI.unescapeHTML(response.body), "Stopped by Kacper at 02:47. What is on master stays."
      assert_select "form[action='#{stop_workshop_design_import_path(running)}']", false
      assert_select "button", text: "Resume"

      get workshop_designs_overview_path(tab: "imports")
      assert_includes css_select("[data-import-entry='#{running.id}']").first.text.squish, "Stopped"
    end
  end

  test "Built says which contexts were built from the code" do
    with_designs do
      @project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p", position: 0)
      @project.design_setup_roles.create!(name: "Flosis staff", code_only: true, position: 1)
      import = first_import([ [ "Library", "done", { from_code: %w[2-flosis-staff] } ] ])

      get workshop_designs_overview_path(tab: "imports", import: import.id)
      assert_includes response.body, "From code: Flosis staff"
    end
  end

  # Kacper, 2026-11-22: the import ends with what it needs from the person.
  test "Feedback shows the open suggestions once the import is over" do
    with_designs do
      import = first_import([ [ "Library", "done" ] ])
      role = @project.design_setup_roles.create!(name: "PO", login_url: "https://s.test/login", username: "po", password: "p", position: 0)
      DesignImportSuggestion.record!(import, kind: "context", title: "Flosis staff sees the Library", context_name: "Flosis staff", features: %w[library])
      DesignImportSuggestion.record!(import, kind: "sign_in", title: "PO could not sign in", detail: "Wrong password.", role: role)

      get workshop_designs_overview_path(tab: "imports", import: import.id)
      page = CGI.unescapeHTML(response.body)
      assert_includes page, "FEEDBACK · 2"
      assert_includes page, "Flosis staff sees the Library"
      [ "Build from code", "Add login", "Fix login", "Dismiss" ].each { |label| assert_includes page, label, label }

      get workshop_designs_overview_path(tab: "imports")
      assert_includes css_select("[data-import-entry='#{import.id}']").first.text.squish, "2 suggestions"

      running = @project.design_setups.create!(kind: "resync", since_setup: import, status: "active", phase: "feature", step: 3, started_by: users(:one))
      DesignImportSuggestion.record!(running, kind: "other", title: "No invoices on staging")
      get workshop_designs_overview_path(tab: "imports", import: running.id)
      refute_includes response.body, "FEEDBACK"
    end
  end

  # Kacper, 2026-11-22 ("żeby ktoś mógł szybko zaakceptować zmiany a nie
  # czekał"): an accepted proposal leaves Needs you at once and waits here
  # while a job lands it, and the page refreshes until it has.
  test "an accepted proposal waits under Landing on master, and the page refreshes until it lands" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "landing", { queued_at: Time.zone.local(2026, 11, 22, 15, 21) } ], [ "Settings", "done" ] ])
      get workshop_designs_overview_path(tab: "imports", import: import.id)

      assert_select "[data-import-landing=bug-reporting]", text: /Bug Reporting\s*· accepted 15:21/
      assert_includes CGI.unescapeHTML(response.body), "LANDING ON MASTER · 1"
      assert_select "[data-import-card=bug-reporting]", false
      assert_select "[data-controller=designs-refresh]"
    end
  end
end
