require "test_helper"

class ProjectDesignSettingsTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "a new project has Designs off and the Tailwind v4 kit" do
    project = Project.new(name: "New", workspace: workspaces(:one), color: "#3B82F6")
    assert_equal false, project.designs_enabled
    assert_equal "tailwind4", project.design_base_kit
  end

  test "the base kit must be one Flosis supports" do
    @project.design_base_kit = "bootstrap5"
    assert_not @project.valid?
    assert_includes @project.errors[:design_base_kit], "is not included in the list"
  end

  test "the design repo is owner/name or blank" do
    @project.design_repo = "https://github.com/acme/designs"
    assert_not @project.valid?
    @project.design_repo = "acme/designs"
    assert @project.valid?
    @project.design_repo = ""
    assert @project.valid?
  end

  test "the design repo token is encrypted at rest" do
    @project.update!(design_repo_token: "ghp_secret")
    raw = Project.connection.select_value("SELECT design_repo_token FROM projects WHERE id = #{@project.id}")
    assert_not_equal "ghp_secret", raw
    assert_equal "ghp_secret", @project.reload.design_repo_token
  end

  test "ensure_design_preview_token! makes one long random token and keeps it" do
    token = @project.ensure_design_preview_token!
    assert_match(/\A[a-zA-Z0-9]{32}\z/, token)
    assert_equal token, @project.reload.ensure_design_preview_token!
  end

  test "the design repo token never falls back to another credential" do
    @project.update!(github_token: "app-repo-token", design_repo: "acme/designs", design_repo_token: nil)
    creds = ProjectCredentials.new(@project)
    assert_nil creds.design_repo_token
    assert_not creds.design_repo_configured?

    @project.update!(design_repo_token: "design-token")
    assert creds.design_repo_configured?
  end
end
