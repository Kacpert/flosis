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
    @project.design_setups.create!(status: "failed", phase: "map", step: 2, started_by: users(:one), error: "The map found no features.")

    get workshop_design_setup_run_path
    assert_response :success
    assert_includes response.body, "The build stopped"
    assert_includes response.body, "The map found no features."
    assert_select "form[action=?]", retry_workshop_design_setup_run_path
  end

  test "Designs stays open while a resync runs, and Imports offers a new one" do
    with_designs do
      first = first_import([ [ "Bug Reporting", "done" ] ])
      @project.design_setups.create!(kind: "resync", since_setup: first, status: "active", phase: "resync", step: 2, started_by: users(:one))
      get workshop_designs_overview_path(tab: "imports")
      assert_response :success
      assert_includes response.body, "Changes since Nov 3"
      assert_select "form[action=?]", workshop_design_imports_path, false, "not while one runs"
    end
  end

  test "Imports offers a new import once the last one is over" do
    with_designs do
      first_import([ [ "Bug Reporting", "done" ] ])
      get workshop_designs_overview_path(tab: "imports")
      assert_select "form[action=?]", workshop_design_imports_path, text: /New import/
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

  test "once master has the first import its page is in Designs" do
    with_designs do
      import = first_import([ [ "Bug Reporting", "done" ] ])
      get workshop_design_setup_run_path
      assert_redirected_to workshop_designs_overview_path(tab: "imports", import: import.id)
    end
  end
end
