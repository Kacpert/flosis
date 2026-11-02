require "test_helper"

class Workshop::DesignSetupsControllerTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper

  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true, design_repo: "a/b", design_repo_token: "t", design_repo_status: "ready",
                     design_preview_token: "t0k", design_app_url: "https://app.test")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "p4ssword")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
    ENV["FLOSIS_DESIGNS_SETUP_API_KEY"] = "sk-flosis"
  end

  teardown { ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY") }

  def staff! = users(:one).update!(flosis_staff: true)

  test "a workspace admin who isn't staff gets a 404" do
    post start_workshop_design_setup_path
    assert_response :not_found
    get workshop_design_setup_path
    assert_response :not_found
    assert_equal 0, @project.design_setups.count
  end

  test "staff start a setup, which begins with the crawl" do
    staff!
    assert_enqueued_with(job: Designs::CrawlJob) { post start_workshop_design_setup_path }
    assert_redirected_to workshop_design_setup_path
    setup = @project.design_setups.active.sole
    assert_equal "design_system", setup.phase
    assert setup.crawl_requested_at
    assert_equal 1, ChatSession.where(project: @project, purpose: "designs_setup").count
  end

  test "starting twice reopens the same setup" do
    staff!
    post start_workshop_design_setup_path
    assert_no_enqueued_jobs(only: Designs::CrawlJob) { post start_workshop_design_setup_path }
    assert_equal 1, @project.design_setups.active.count
    assert_equal 1, ChatSession.where(project: @project, purpose: "designs_setup").count
  end

  test "without Flosis's setup key nothing starts" do
    staff!
    ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
    post start_workshop_design_setup_path
    assert_equal 0, @project.design_setups.count
    assert_match(/FLOSIS_DESIGNS_SETUP_API_KEY/, flash[:alert])
  end

  test "the phases advance in order" do
    staff!
    post start_workshop_design_setup_path
    post next_phase_workshop_design_setup_path
    post next_phase_workshop_design_setup_path
    assert_equal "designs", @project.design_setups.active.sole.phase
    assert_equal [ "Phase: Components.", "Phase: Designs." ],
                 ChatSession.find_by!(project: @project, purpose: "designs_setup").chat_messages.where(kind: "system").ordered.pluck(:content)
  end

  test "the screen shows the phase, the crawl and the chat, and a message starts a setup turn" do
    staff!
    post start_workshop_design_setup_path
    get workshop_design_setup_path
    assert_response :success
    assert_select "body", %r{Setup · #{@project.name} · Phase 1/3: Design system}
    assert_select "body", /Crawling…/
    assert_select "turbo-frame#designs-chat"
    assert_select "form[action=?]", next_phase_workshop_design_setup_path
    assert_select "form[action=?]", approve_workshop_design_setup_path, count: 0

    assert_enqueued_with(job: Designs::TurnJob) do
      post message_workshop_design_setup_path, params: { content: "Start with the tokens" }
    end
    turn = DesignTurn.last
    assert_equal [ "designs_setup", @project ], [ turn.chat_session.purpose, turn.chat_session.project ]

    @project.design_setups.active.sole.update!(crawl_error: "Login failed", phase: "designs")
    get workshop_design_setup_path
    assert_select "body", /Crawl failed: Login failed/
    assert_select "form[action=?]", approve_workshop_design_setup_path
  end

  test "approving the setup brings it into master" do
    staff!
    with_design_remote(@project) do |repo, remote|
      seed_master(repo)
      post start_workshop_design_setup_path
      commit_files(repo, repo.worktree!("wip/setup"), { "design-system/tokens.css" => ":root {}" })
      @project.design_setups.active.sole.update!(phase: "designs")
      with_remote_url(remote) { post approve_workshop_design_setup_path }
      assert_equal "Setup approved as version 1.", flash[:clar_toast]
      assert_equal "approved", @project.design_setups.sole.status
      assert_includes GitRunner.run!("ls-tree", "-r", "--name-only", "refs/heads/master", chdir: remote), "design-system/tokens.css"
    end
  end
end
