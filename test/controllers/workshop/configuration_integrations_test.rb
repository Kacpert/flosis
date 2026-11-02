require "test_helper"

class Workshop::ConfigurationIntegrationsTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # admin/owner with config access
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "the integrations tab renders (exercises the editable Jira partial)" do
    get workshop_configuration_path(tab: "integrations")
    assert_response :success
    assert_select "input[name='project[jira_site]']"
    assert_select "input[name='project[jira_api_token]']"
    # Scoped to this modal: the topbar's New project dialog carries a field of
    # the same name, so a bare selector passes without the Jira partial.
    assert_select "[data-clar-modal-panel-id-value='manage-jira'] input[name='project[external_reference]']"
  end

  # The PR tab's "Go to Configuration" names the dialog to open, so it lands on
  # the review switch instead of a page of cards with no sign of it.
  test "a link naming an integration opens its dialog" do
    get workshop_configuration_path(tab: "integrations", manage: "github")

    assert_response :success
    assert_select "[data-controller='clar-modal'][data-clar-modal-open-value='manage-github']"
  end

  test "a link naming no known integration opens nothing" do
    get workshop_configuration_path(tab: "integrations", manage: "nope")

    assert_response :success
    assert_select "[data-clar-modal-open-value]", count: 0
  end

  # PROJECT KEY was a read-only box and external_reference was not a permitted
  # field, so a project that reused Jira credentials could never be given a
  # board afterwards — it stayed connected to Jira and able to return nothing.
  test "saving jira persists the project key" do
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", external_reference: "PPL" }
    }

    assert_equal "PPL", @project.reload.external_reference
  end

  # The point of making the key editable: a project created with "Set up later"
  # must be able to become a Jira project afterwards. Nothing else in the
  # Workshop can set external_type, and without it the sync never runs.
  test "filling in the site and the key makes a project a Jira project" do
    @project.update!(external_type: nil, external_reference: nil)

    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", external_reference: "PPL" }
    }

    assert @project.reload.jira_connected?
  end

  # The pair is what counts, as in ProjectCreator: credentials with no key sync
  # nothing while the health check still succeeds.
  test "a site without a key does not make a project a Jira project" do
    @project.update!(external_type: nil, external_reference: nil)

    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", external_reference: "" }
    }

    assert_not @project.reload.jira_connected?
  end

  test "saving jira creds persists encrypted token to the project" do
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt-secret" }
    }
    @project.reload
    assert_equal "acme.atlassian.net", @project.jira_site
    assert_equal "jt-secret", @project.jira_api_token
    raw = Project.connection.select_value("SELECT jira_api_token FROM projects WHERE id=#{@project.id}")
    assert_not_equal "jt-secret", raw
  end

  test "blank jira token preserves the existing value" do
    @project.update!(jira_api_token: "keep-me")
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "" }
    }
    assert_equal "keep-me", @project.reload.jira_api_token
  end

  test "regenerates the mcp config on jira save when the project has a folder" do
    @project.update!(workspace_dir: Project::ELVIUM_LEGACY_DIR)
    wrote = []
    orig = ProjectMcpConfig.method(:write!)
    ProjectMcpConfig.define_singleton_method(:write!) { |p| wrote << p.id; "x" }
    begin
      patch workshop_configuration_path(tab: "integrations"), params: {
        integration: "jira",
        project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt" }
      }
    ensure
      ProjectMcpConfig.define_singleton_method(:write!, orig)
    end
    assert_includes wrote, @project.id
  end

  # The GitHub modal names its integration like the others; without it the save
  # would permit nothing and silently store no change.
  test "saving github persists the repo and token to the project" do
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "github",
      project: { github_repo: "acme/repo", github_token: "gh-secret" }
    }
    @project.reload
    assert_equal "acme/repo", @project.github_repo
    assert_equal "gh-secret", @project.github_token
  end

  # Saving a branch is what moves the server's checkout onto it.
  test "saving github with a branch stores it and starts the checkout" do
    assert_enqueued_with(job: ProjectRepoCheckoutJob, args: [ @project.id ]) do
      patch workshop_configuration_path(tab: "integrations"), params: {
        integration: "github",
        project: { github_repo: "https://github.com/acme/repo", github_branch: "production", github_token: "gh-secret" }
      }
    end
    @project.reload
    assert_equal "acme/repo", @project.github_repo
    assert_equal "production", @project.github_branch
  end

  test "a branch git would take for an option is refused and not stored" do
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "github", project: { github_repo: "acme/repo", github_branch: "--upload-pack=x" }
    }
    assert_nil @project.reload.github_branch
    assert_match "not a branch name", flash[:alert]
  end

  # fetch(..., []) permitted nothing, wrote nothing, and still toasted
  # "Integration settings saved" — one forgotten hidden_field_tag away from a
  # form that silently does nothing.
  test "an unknown integration saves nothing and says so" do
    @project.update!(jira_site: "keep.atlassian.net")

    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "slack",
      project: { jira_site: "changed.atlassian.net" }
    }

    assert_equal "keep.atlassian.net", @project.reload.jira_site
    assert_match(/Unknown integration/, flash[:alert])
    refute_match(/Integration settings saved/, flash[:clar_toast].to_s)
  end

  test "a save with no integration named saves nothing and says so" do
    @project.update!(jira_site: "keep.atlassian.net")

    patch workshop_configuration_path(tab: "integrations"), params: {
      project: { jira_site: "changed.atlassian.net" }
    }

    assert_equal "keep.atlassian.net", @project.reload.jira_site
    assert_match(/Unknown integration/, flash[:alert])
    refute_match(/Integration settings saved/, flash[:clar_toast].to_s)
  end

  # button_to renders its own <form>. Inside the credentials form the browser
  # drops it and the button becomes a submit button for the OUTER form, so
  # "Test connection" PATCHed the credentials instead of running the health
  # check. An HTML parser drops it the same way, which is what this asserts:
  # the form is only findable once it is a sibling. The Jira modal keeps its
  # two buttons outside the credential form for this reason.
  test "the GitHub connection test posts its own form, not the credentials one" do
    get workshop_configuration_path(tab: "integrations")

    assert_response :success
    assert_select "form[action=?]", workshop_test_github_configuration_path
  end
end
