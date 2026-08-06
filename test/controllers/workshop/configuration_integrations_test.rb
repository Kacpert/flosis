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

  test "legacy workspace github save still works (integration param absent)" do
    patch workshop_configuration_path(tab: "integrations"), params: {
      workspace: { github_repo: "ws/repo", github_token: "wt" }
    }
    assert_equal "ws/repo", @workspace.reload.github_repo
  end
end
