require "test_helper"

# The Designs setup form (Workshop Designs v2, against the copy of Kacper's
# ClearBacklog-3.html) and its progress screen (the Designs setup, feature by
# feature, against the mockup he approved).
class Workshop::DesignSetupRunsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  FORM = {
    framework: "html", ui: "tailwind", ui_version: "4", repo: "github.com/acme/app-designs", repo_token: "ghp_designs_token",
    repos: { "0" => { role: "Frontend", url: "github.com/acme/app@production" } },
    contexts: { "0" => { name: "Admin", url: "https://staging.acme.test/login", login: "admin@staging.test", password: "secret-pass" } }
  }.freeze

  test "the form is the design's: technology, repositories, the test environment and contexts" do
    get new_workshop_design_setup_run_path
    assert_response :success
    [ "Set up Designs for #{@project.name}", "The AI reads your repositories, signs in to your test environment as each context, maps the app’s features and builds them one by one: the design system, the components and every screen, in the designs repository. It runs in the background and takes several hours. After that, every change happens in threads.",
      "Technology", "What the designs are built with. Components are generated in this stack and version.", "FRAMEWORK",
      "Vue.js", "React", "Angular", "HTML + CSS", "SOON", "UI SYSTEM", "Foundation", "Bootstrap", "Tailwind", "Material", "Custom",
      "The AI checks these against package.json and the lockfile and flags a mismatch.",
      "Repositories", "Where the designs are stored, and the product code they are based on.", "DESIGNS REPOSITORY (TARGET)",
      "The AI commits here. master holds approved designs; each thread is a branch.", "CURRENT APP REPOSITORIES · READ-ONLY",
      "Add repository", "Frontend, backend, shared UI library… The AI uses them to match real components, copy, routes and data.",
      "Test environment and contexts", "The AI signs in as each context and uses the app on test data: it may create, change and delete what it needs. Use a test environment (staging, or a test workspace on production) and a test account per context. Each context can have its own login page.",
      "CONTEXT", "LOGIN URL", "LOGIN", "PASSWORD", "Add context", "Several hours, in the background. You can keep working.",
      "Build designs" ].each { |copy| assert_includes response.body, CGI.escapeHTML(copy), copy }
    assert_select "input[name=framework][value=vue]", count: 0
    assert_select "input[name=framework][value=html]"
    assert_select "input[name=framework_version]", count: 0
  end

  # A run lasts hours: a second click of Build designs, or a re-import while
  # it runs, must not start another on the same branch.
  test "a second Build while a run goes starts nothing" do
    running = @project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one))
    assert_no_difference -> { DesignSetup.count } do
      post workshop_design_setup_run_path, params: FORM
      patch workshop_design_setup_run_path, params: FORM
    end
    assert_redirected_to workshop_design_setup_run_path
    assert_equal "A setup is already running. It goes on from where it is.", flash[:clar_toast]
    assert_no_enqueued_jobs only: Designs::SetupRunJob
    assert running.reload.status == "active"
  end

  test "an incomplete form says what is missing and starts nothing" do
    post workshop_design_setup_run_path, params: FORM.merge(repo: "")
    assert_response :unprocessable_entity
    assert_includes response.body, Workshop::DesignSetupRunsController::INCOMPLETE
    assert_no_enqueued_jobs only: Designs::SetupRunJob
  end

  # The app's own repository as the target was refused by the record, and the
  # refusal escaped as a bare 422: the form came back with no word of why.
  test "the app's own repository as the target says why and starts nothing" do
    post workshop_design_setup_run_path, params: FORM.merge(repo: "github.com/acme/app.git")

    assert_response :unprocessable_entity
    assert_includes response.body, "Design repo must be a different repository from the app&#39;s"
    assert_nil @project.reload.design_repo
    assert_no_enqueued_jobs only: Designs::SetupRunJob
  end

  test "Build designs saves the setup and starts the import in the background" do
    post workshop_design_setup_run_path, params: FORM

    @project.reload
    assert_equal [ "html", "tailwind", "4", "acme/app-designs", "tailwind4", "https://staging.acme.test" ],
                 [ @project.designs_framework, @project.designs_ui_system, @project.designs_ui_version, @project.design_repo,
                   @project.design_base_kit, @project.design_app_url ]
    assert_equal [ { "role" => "Frontend", "repo" => "acme/app@production" } ], @project.design_app_repos
    assert_equal "ghp_designs_token", @project.design_repo_token
    role = @project.design_setup_roles.sole
    assert_equal [ "Admin", "https://staging.acme.test/login", "admin@staging.test", "secret-pass" ], [ role.name, role.login_url, role.username, role.password ]
    setup = @project.design_setups.sole
    assert_enqueued_with(job: Designs::SetupRunJob, args: [ setup.id ])
    assert_redirected_to workshop_design_setup_run_path
    assert_equal "Building designs in the background · several hours", flash[:clar_toast]
  end

  # A run four features long, half way: the app shell matched, Holidays done
  # with a note, the pipeline being checked (its progress file says so), and
  # the Jira browser up next, with a note the map left.
  def run_half_way
    @project.update!(workspace_dir: Dir.mktmpdir("setup-progress"), design_repo: "acme/app-designs", designs_ui_system: "tailwind",
                     designs_ui_version: "4", design_app_url: "https://staging.acme.test",
                     design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app@production" } ])
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://staging.acme.test/login", username: "a", password: "p", position: 0)
    setup = @project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one), step_seconds: [ 720, 120, 1260, 2040 ])
    setup.add_features!([
      { "name" => "App shell", "contexts" => %w[1-admin], "screens" => [ "Home", "Sign in" ] },
      { "name" => "Holidays", "contexts" => %w[1-admin], "screens" => [ "Requests" ] },
      { "name" => "Create Tasks pipeline", "contexts" => %w[1-admin], "screens" => %w[Pipeline Ready Versions] },
      { "name" => "Jira browser", "contexts" => %w[1-admin], "screens" => %w[Board Issue Sprint], "notes" => [ "The test Jira project has no sprints yet." ] }
    ])
    shell, holidays, pipeline = setup.features.to_a
    shell.update!(status: "done", components_new: 9, started_at: 38.minutes.ago, finished_at: Time.current)
    holidays.update!(status: "done", components_new: 1, components_reused: 6, notes: [ "No pending requests in the test data." ],
                     started_at: 29.minutes.ago, finished_at: Time.current)
    pipeline.update!(status: "running", stage: "building", started_at: 10.minutes.ago)
    File.write(setup.run_dir.tap(&:mkpath).join("progress.json"), { feature: pipeline.key, screens: { "Pipeline" => "done", "Ready" => "checking" } }.to_json)
    setup
  end

  def page_has(*copies)
    copies.each { |copy| assert_includes response.body, CGI.escapeHTML(copy), copy }
  end

  test "the progress screen shows the run's steps, as the run stands" do
    setup = run_half_way
    get workshop_design_setup_run_path
    assert_response :success
    page_has "Running in the background", "Building designs for #{@project.name}",
             "This takes several hours: the features are built one by one, and each is checked against the app before the next one starts. You can leave this page and keep working. We’ll notify you when master is ready.",
             "staging.acme.test, as Admin", "#{setup.percent}%", setup.time_left,
             "Reading acme/app @ production", "Signing in as Admin", "Mapping features: 4 found",
             "Design system: tokens, fonts and icons from Tailwind 4", "Building features one by one: 2 of 4 done",
             "Committing to acme/app-designs @ master", "12 min", "21 min", "34 min", "~3 min", "Continue working"
    assert_select "button", text: "Retry", count: 0
  end

  test "the progress screen lists the features and the notes for you" do
    run_half_way
    get workshop_design_setup_run_path
    page_has "Notes for you", "2 · nothing is blocked", "HOLIDAYS · DONE", "No pending requests in the test data.",
             "JIRA BROWSER · UP NEXT", "The test Jira project has no sprints yet.",
             "Features", "2 done · 1 in progress · 1 to do",
             "App shell", "Admin · 2 screens · 9 new components", "Matches the app", "38 min",
             "Holidays", "Admin · 1 screen · 1 new component, 6 reused", "Done · 1 note", "29 min",
             "Create Tasks pipeline", "Checking against the app", "screen 2 of 3", "Ready · checking", "Versions",
             "Jira browser", "Admin · about 3 screens", "Up next"
  end

  test "a stopped run shows its error and Retry, which goes on from where it stopped" do
    setup = run_half_way
    setup.update!(status: "failed", error: "No context could sign in to the test environment: login failed.")
    get workshop_design_setup_run_path
    page_has "The build stopped", "No context could sign in to the test environment: login failed."
    assert_select "button", text: "Retry"

    post retry_workshop_design_setup_run_path
    assert_equal [ "active", nil ], [ setup.reload.status, setup.error ]
    assert_enqueued_with(job: Designs::SetupRunJob, args: [ setup.id ])
  end

  test "Designs shows the progress while the first import runs, and the sidebar blinks" do
    @project.design_setups.create!(status: "active", phase: "design_system", step: 0, started_by: users(:one))
    get workshop_designs_overview_path
    assert_redirected_to workshop_design_setup_run_path
    get workshop_pipeline_path
    assert_select "[title=?]", "Building designs in the background"
  end

  test "whoever started the setup is told once that master is ready" do
    @project.design_setups.create!(status: "approved", phase: "feature", step: 7, started_by: users(:one), finished_at: Time.current)
    get workshop_pipeline_path
    assert_includes response.body, "Designs ready · #{@project.name} @ master"
    get workshop_pipeline_path
    assert_not_includes response.body, "Designs ready · #{@project.name} @ master"
  end

  # A deploy cut it off: Designs::ResumeSetupsJob picks it up again, so the
  # page does not fail it.
  test "a run a deploy cut off still shows as running" do
    setup = @project.design_setups.create!(status: "active", phase: "feature", step: 4, started_by: users(:one),
                                           unit_job_id: "gone", unit_deadline_at: 1.minute.ago)
    setup.update_columns(updated_at: 3.hours.ago)

    get workshop_design_setup_run_path
    assert_equal "active", setup.reload.status
    assert_includes response.body, "Running in the background"
  end

end
