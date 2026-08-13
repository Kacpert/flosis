require "test_helper"

class Workshop::ConfigurationControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "admin GET show renders the Configuration shell and AI tab by default" do
    get workshop_configuration_path

    assert_response :success
    assert_select "h1", "Configuration"
    assert_select "body", /Per-project credentials, AI behaviour and access\./
    assert_select ".clar-tab", /Integrations/
    assert_select ".clar-tab", /AI/
    assert_select ".clar-tab", /Users/ # admin sees the Users tab

    # AI tab content (default tab)
    assert_select "body", /Claude Opus/
    assert_select "body", /active/
    assert_select "body", /Configurable dependency\. Only Claude Opus is in scope today\./
    assert_select "textarea"
    assert_select "input[type=range]"
    assert_select "body", /effective minimum 7/
    assert_select "body", /Estimation target/
  end

  test "admin GET show with tab=integrations renders the integrations tab (Task 9.2: 4 cards, no longer a placeholder)" do
    get workshop_configuration_path(tab: "integrations")

    assert_response :success
    assert_select ".clar-tab-active", /Integrations/
    assert_select "body", /GitHub/
    assert_select "body", /Jira Cloud/
    assert_select "body", /Discord/
    assert_select "body", /Figma/
  end

  test "admin GET show with tab=users renders the member list with role badges (Task 9.3)" do
    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select ".clar-tab-active", /Users/

    # Owner (workspace_memberships(:one_owner), users(:one)) -> Administrator
    assert_select "body", /Kacper/
    assert_select "body", /one@example\.com/

    # Employee with workshop_access -> Product Owner (Task 9.3 setup below toggles this on)
    assert_select "body", /Other User/
    assert_select "body", /two@example\.com/

    # Client -> Client
    assert_select "body", /Client Person/
    assert_select "body", /client-fixture@example\.com/

    assert_select ".clar-badge-warn", /Administrator/
    assert_select ".clar-badge-muted", /Client/
  end

  test "users tab shows Product Owner badge for employee with workshop_access" do
    workspace_memberships(:two_employee).update!(workshop_access: true)

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select ".clar-badge-primary", /Product Owner/
  end

  test "users tab shows a muted Member badge for employee without workshop_access" do
    workspace_memberships(:two_employee).update!(workshop_access: false)

    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select ".clar-badge-muted", /Member/
  end

  test "users tab Invite button links to the HR invite screen in a new tab" do
    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select "a[href=?][target=?]", new_workspace_member_path, "_blank", /Invite/
  end

  test "employee is blocked from the users tab too" do
    workspace_memberships(:two_employee).update!(workshop_access: true)
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path(tab: "users")
    assert_redirected_to root_path
  end

  test "employee (non-admin) is blocked from Configuration show AND update" do
    # workshop_access true + workshop_enabled true rule out require_product!/
    # require_workshop! as the cause — so the block is provably require_admin!.
    workspace_memberships(:two_employee).update!(workshop_access: true)
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path
    assert_redirected_to root_path # require_admin! target

    # update must be gated too — a non-admin PATCH must not persist anything.
    before = workspaces(:one).reload.pr_poll_minutes
    patch workshop_configuration_path, params: { workspace: { pr_poll_minutes: 25 } }
    assert_redirected_to root_path
    assert_equal before, workspaces(:one).reload.pr_poll_minutes, "employee PATCH must not persist"
  end

  test "workspace_client can reach Configuration (AI tab) and manage settings, but NOT the users tab" do
    workspace_memberships(:two_employee).update!(role: "workspace_client")
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    # Can open Configuration and its non-users tabs.
    get workshop_configuration_path
    assert_response :success
    assert_select ".clar-tab", /AI/
    # The Users tab is SHOWN but locked for a workspace_client — visible with a
    # reason beats silently missing. It must not be a link, and the server-side
    # block below is what actually enforces it.
    assert_select "a.clar-tab", text: /Users/, count: 0
    assert_select "span.clar-tab[aria-disabled='true']", text: /Users/ do |tab|
      assert_match(/Missing permission/, tab.first["title"], "locked tab must say why")
    end

    # Can manage settings — a real management action (AI tab) persists.
    before = workspaces(:one).reload.pr_poll_minutes
    patch workshop_configuration_path, params: { tab: "ai", workspace: { pr_poll_minutes: 21 } }
    assert_equal 21, workspaces(:one).reload.pr_poll_minutes, "workspace_client must be able to manage settings"

    # But is blocked from the users tab (show) and any users-tab update.
    get workshop_configuration_path(tab: "users")
    assert_redirected_to workshop_configuration_path(tab: "ai")
  end

  test "PATCH update persists AI settings and toasts" do
    patch workshop_configuration_path, params: {
      workspace: {
        pr_review_prompt: "Custom prompt text for reviews.",
        pr_poll_minutes: 15,
        estimation_trigger: "status",
        estimation_field_names: [ "Story point estimate", "Confidence (1–5)" ],
        estimation_status_trigger: "Ready for dev",
        figma_read_enabled: true
      },
      tab: "ai"
    }

    assert_redirected_to workshop_configuration_path(tab: "ai")
    @workspace.reload
    assert_equal "Custom prompt text for reviews.", @workspace.pr_review_prompt
    assert_equal 15, @workspace.pr_poll_minutes
    assert_equal "status", @workspace.estimation_trigger
    assert_equal [ "Story point estimate", "Confidence (1–5)" ], @workspace.estimation_field_names
    assert_equal true, @workspace.figma_read_enabled
    assert_match(/AI settings saved/, flash[:clar_toast])
  end

  test "PATCH update saves briefing_personas onto the current workshop project" do
    patch workshop_configuration_path, params: {
      workspace: { briefing_personas: "  Recruiters posting jobs; Admins configuring.  " },
      tab: "briefing"
    }

    assert_redirected_to workshop_configuration_path(tab: "briefing")
    assert_equal "Recruiters posting jobs; Admins configuring.", @project.reload.briefing_personas
    assert_match(/Briefing settings saved/, flash[:clar_toast])
  end

  test "the Briefing tab shows the personas field, the feature-summary card, and a Refresh button" do
    @project.update!(briefing_personas: "Recruiters and admins.",
                     features_summary: "Users can post jobs and review candidates.",
                     features_summary_updated_at: 2.hours.ago)

    get workshop_configuration_path(tab: "briefing")

    assert_response :success
    assert_select ".clar-tab.clar-tab-active", /Briefing/
    assert_select "textarea[name='workspace[briefing_personas]']", /Recruiters and admins\./
    assert_select "body", /what the app already does/i
    assert_select "body", /Users can post jobs and review candidates\./
    assert_select "form[action='#{workshop_refresh_features_configuration_path}']"
  end

  test "the AI tab no longer carries the briefing personas field" do
    get workshop_configuration_path(tab: "ai")

    assert_response :success
    assert_select "textarea[name='workspace[briefing_personas]']", false
  end

  test "refresh_features enqueues a single-project scan and toasts" do
    assert_enqueued_with(job: ProjectFeaturesScanJob, args: [ @project.id ]) do
      post workshop_refresh_features_configuration_path
    end

    assert_redirected_to workshop_configuration_path(tab: "briefing")
    assert_match(/Refreshing the app feature summary/, flash[:clar_toast])
  end

  test "PATCH update rejects a blank estimation_field_names array" do
    original = @workspace.estimation_field_names

    patch workshop_configuration_path, params: {
      workspace: { estimation_field_names: [ "" ] },
      tab: "ai"
    }

    @workspace.reload
    assert_equal original, @workspace.estimation_field_names
  end

  # ---- Integrations tab (Task 9.2) ----------------------------------------

  test "integrations tab renders the 4 cards with live status/detail" do
    @workspace.update!(
      github_repo: "acme/survey-platform", github_token: "ghp_abcd1234a3f1",
      github_status_ok: true, github_status_checked_at: 2.hours.ago,
      pr_review_enabled: true, figma_read_enabled: true
    )
    DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/a")
    DiscordWebhook.create!(workspace: @workspace, channel_name: "#product", url: "https://discord.com/api/webhooks/2/b")
    ENV["JIRA_DOMAIN"] = "acme.atlassian.net"
    ENV["JIRA_EMAIL"] = "a@example.com"
    ENV["JIRA_API_TOKEN"] = "tok"

    get workshop_configuration_path(tab: "integrations")

    assert_response :success
    assert_select "body", /GitHub/
    assert_select "body", /acme\/survey-platform/
    assert_select "body", /a3f1/
    assert_select "body", /Jira Cloud/
    assert_select "body", /Connected/
    assert_select "body", /Discord/
    assert_select "body", /2 webhooks/
    assert_select "body", /Figma/
  end

  test "employee is blocked from the integrations endpoints too" do
    workspace_memberships(:two_employee).update!(workshop_access: true)
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path(tab: "integrations")
    assert_redirected_to root_path

    post workshop_test_github_configuration_path
    assert_redirected_to root_path

    post workshop_verify_jira_fields_configuration_path
    assert_redirected_to root_path
  end

  test "POST test_github runs the health check, persists status, and toasts" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets")
    fake = Object.new
    fake.define_singleton_method(:health_check) { { ok: true } }
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }

    post workshop_test_github_configuration_path

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    @workspace.reload
    assert @workspace.github_status_ok
    assert_match(/GitHub connection OK/, flash[:clar_toast])
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  test "POST test_github stores the error when the health check fails" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets")
    fake = Object.new
    fake.define_singleton_method(:health_check) { { ok: false, error: "401 Unauthorized" } }
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }

    post workshop_test_github_configuration_path

    @workspace.reload
    assert_not @workspace.github_status_ok
    assert_equal "401 Unauthorized", @workspace.github_status_error
    assert_match(/GitHub connection failed/, flash[:clar_toast])
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  test "POST verify_jira_fields resolves and caches the 3 field ids and toasts" do
    ENV["JIRA_DOMAIN"] = "acme.atlassian.net"
    ENV["JIRA_EMAIL"] = "a@example.com"
    ENV["JIRA_API_TOKEN"] = "tok"
    @workspace.update!(jira_ai_actions_field_id: nil, jira_ai_estimation_field_id: nil, jira_story_points_field_id: nil)

    fake = Object.new
    fake.define_singleton_method(:fetch_field_id) do |name|
      { "AI actions" => "customfield_1", "AI estimation" => "customfield_2", "Story point estimate" => "customfield_3" }[name]
    end
    orig = JiraClient.method(:new)
    JiraClient.define_singleton_method(:new) { |*_a, **_k| fake }

    post workshop_verify_jira_fields_configuration_path

    assert_redirected_to workshop_configuration_path(tab: "integrations")
    @workspace.reload
    assert_equal "customfield_1", @workspace.jira_ai_actions_field_id
    assert_equal "customfield_2", @workspace.jira_ai_estimation_field_id
    assert_equal "customfield_3", @workspace.jira_story_points_field_id
    assert_match(/fields verified/i, flash[:clar_toast])
  ensure
    JiraClient.define_singleton_method(:new, orig)
  end

  test "PATCH update persists GitHub modal fields and a blank token keeps the existing one" do
    @workspace.update!(github_repo: "acme/old", github_token: "existing-token", pr_review_enabled: false)

    patch workshop_configuration_path, params: {
      workspace: { github_repo: "acme/new-repo", github_token: "", pr_review_enabled: true },
      tab: "integrations"
    }

    @workspace.reload
    assert_equal "acme/new-repo", @workspace.github_repo
    assert_equal "existing-token", @workspace.github_token, "blank token must not wipe the existing one"
    assert_equal true, @workspace.pr_review_enabled
  end

  test "PATCH update persists a non-blank GitHub token (rotate)" do
    @workspace.update!(github_token: "old-token")

    patch workshop_configuration_path, params: {
      workspace: { github_token: "brand-new-token" },
      tab: "integrations"
    }

    assert_equal "brand-new-token", @workspace.reload.github_token
  end

  test "PATCH update persists figma_read_enabled from the integrations tab" do
    @workspace.update!(figma_read_enabled: false)

    patch workshop_configuration_path, params: {
      workspace: { figma_read_enabled: true },
      tab: "integrations"
    }

    assert_equal true, @workspace.reload.figma_read_enabled
  end
end
