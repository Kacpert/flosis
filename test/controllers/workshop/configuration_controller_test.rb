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
    assert_select "body", /ADMINISTRATOR ONLY/
    assert_select "h1", "Configuration"
    assert_select "body", /Per-project credentials, AI behaviour and access\. Hidden from Product Owners\./
    assert_select ".clar-tab", /Integrations/
    assert_select ".clar-tab", /AI/
    assert_select ".clar-tab", /Users/

    # AI tab content (default tab)
    assert_select "body", /Claude Opus/
    assert_select "body", /active/
    assert_select "body", /Configurable dependency\. Only Claude Opus is in scope today\./
    assert_select "textarea"
    assert_select "input[type=range]"
    assert_select "body", /effective minimum 7/
    assert_select "body", /Estimation target/
  end

  test "admin GET show with tab=integrations renders the integrations placeholder" do
    get workshop_configuration_path(tab: "integrations")

    assert_response :success
    assert_select ".clar-tab-active", /Integrations/
    assert_select "body", /later step/
  end

  test "admin GET show with tab=users renders the users placeholder" do
    get workshop_configuration_path(tab: "users")

    assert_response :success
    assert_select ".clar-tab-active", /Users/
    assert_select "body", /later step/
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

  test "PATCH update rejects a blank estimation_field_names array" do
    original = @workspace.estimation_field_names

    patch workshop_configuration_path, params: {
      workspace: { estimation_field_names: [ "" ] },
      tab: "ai"
    }

    @workspace.reload
    assert_equal original, @workspace.estimation_field_names
  end
end
