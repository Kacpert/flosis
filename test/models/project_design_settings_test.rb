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

  # For Elvium, workspace_dir is the app checkout itself (~/work/elvium): a
  # design clone in there would sit inside the app's own working tree.
  test "a legacy Elvium project keeps its designs in a folder of its own, outside the app checkout" do
    @project.workspace_dir = Project::ELVIUM_LEGACY_DIR
    assert_equal File.join(Project::CLIENTS_BASE_DIR, @project.workspace_id.to_s, @project.id.to_s), @project.designs_dir
    assert_equal Project::ELVIUM_LEGACY_DIR, @project.workspace_dir
  end

  test "any other project keeps its designs in its workspace folder, assigned the first time it is needed" do
    @project.update_columns(workspace_dir: nil)
    default = File.join(Project::CLIENTS_BASE_DIR, @project.workspace_id.to_s, @project.id.to_s)
    assert_equal default, @project.designs_dir
    assert_equal default, @project.reload.workspace_dir

    @project.update_columns(workspace_dir: "/srv/clients/acme")
    assert_equal "/srv/clients/acme", @project.designs_dir
  end

  # Git's own message is stored here. MySQL in strict mode refuses the 256th
  # character of a string column instead of cutting it, and PostgreSQL's string
  # has no limit, so locally only the column's type can show the difference.
  test "the design repo error holds a full git message" do
    assert_equal :text, Project.columns_hash["design_repo_error"].type

    @project.update!(design_repo_error: "x" * 500)
    assert_equal 500, @project.reload.design_repo_error.length
  end
end
