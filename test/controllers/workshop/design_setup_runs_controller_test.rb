require "test_helper"

# The Designs setup form and its progress (Workshop Designs v2), against the
# copy of Kacper's ClearBacklog-3.html.
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

  test "the form is the design's: technology, repositories, staging and contexts" do
    get new_workshop_design_setup_run_path
    assert_response :success
    [ "Set up Designs for #{@project.name}", "The AI reads your repositories, signs in to staging as each context, and builds the design system, components and today’s screens in the designs repository. It runs in the background and usually takes about an hour. After that, every change happens in threads.",
      "Technology", "What the designs are built with. Components are generated in this stack and version.", "FRAMEWORK",
      "Vue.js", "React", "Angular", "HTML + CSS", "SOON", "UI SYSTEM", "Foundation", "Bootstrap", "Tailwind", "Material", "Custom",
      "The AI checks these against package.json and the lockfile and flags a mismatch.",
      "Repositories", "Where the designs are stored, and the product code they are based on.", "DESIGNS REPOSITORY (TARGET)",
      "The AI commits here. master holds approved designs; each thread is a branch.", "CURRENT APP REPOSITORIES · READ-ONLY",
      "Add repository", "Frontend, backend, shared UI library… The AI uses them to match real components, copy, routes and data.",
      "Staging and contexts", "The AI signs in as each context to capture what that role sees. Each context can have its own login page. Use test accounts.",
      "CONTEXT", "LOGIN URL", "LOGIN", "PASSWORD", "Add context", "About an hour, in the background. You can keep working.",
      "Build designs" ].each { |copy| assert_includes response.body, CGI.escapeHTML(copy), copy }
    assert_select "input[name=framework][value=vue]", count: 0
    assert_select "input[name=framework][value=html]"
    assert_select "input[name=framework_version]", count: 0
  end

  test "an incomplete form says what is missing and starts nothing" do
    post workshop_design_setup_run_path, params: FORM.merge(repo: "")
    assert_response :unprocessable_entity
    assert_includes response.body, Workshop::DesignSetupRunsController::INCOMPLETE
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
    assert_equal "Building designs in the background · about an hour", flash[:clar_toast]
  end

  test "the progress page shows the seven steps, and a failed one with Retry" do
    @project.update!(design_repo: "acme/app-designs", github_repo: "acme/app")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://s.test/login", username: "a", password: "p")
    setup = @project.design_setups.create!(status: "active", phase: "design_system", step: 2, started_by: users(:one))

    get workshop_design_setup_run_path
    [ "Running in the background", "Building designs for #{@project.name}",
      "This usually takes about an hour. You can leave this page and keep working. We’ll notify you when master is ready.",
      "#{setup.percent}%", "About #{setup.minutes_left} min left", "Reading acme/app", "Signing in to staging as Admin",
      "Capturing pages for every context", "Extracting design tokens from Tailwind 4 settings", "Building components in HTML + CSS",
      "Generating screens across 1 contexts", "Committing to acme/app-designs @ master", "~8 min", "Continue working" ].each do |copy|
      assert_includes response.body, CGI.escapeHTML(copy), copy
    end

    setup.update!(status: "failed", error: "The crawl could not sign in as Admin.")
    get workshop_design_setup_run_path
    assert_includes response.body, "The crawl could not sign in as Admin."
    post retry_workshop_design_setup_run_path
    assert_equal "active", setup.reload.status
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
    @project.design_setups.create!(status: "approved", phase: "designs", step: 7, started_by: users(:one), finished_at: Time.current)
    get workshop_pipeline_path
    assert_includes response.body, "Designs ready · #{@project.name} @ master"
    get workshop_pipeline_path
    assert_not_includes response.body, "Designs ready · #{@project.name} @ master"
  end

  test "a run a deploy killed shows as stopped, with Retry" do
    setup = @project.design_setups.create!(status: "active", phase: "components", step: 4, started_by: users(:one))
    setup.update_columns(updated_at: 3.hours.ago)

    get workshop_design_setup_run_path
    assert_equal "failed", setup.reload.status
    assert_includes response.body, DesignTurn::INTERRUPTED
    assert_select "button", text: "Retry"
  end

end
