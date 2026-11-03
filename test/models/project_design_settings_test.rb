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
    @project.design_repo = "acme"
    assert_not @project.valid?
    @project.design_repo = "acme/designs/extra"
    assert_not @project.valid?
    @project.design_repo = "acme/designs"
    assert @project.valid?
    @project.design_repo = ""
    assert @project.valid?
  end

  # In the app this is shown as an alert on the Designs tab, so it has to say
  # what to type, not just that something is wrong.
  test "a repository that is not owner/name says how it should look" do
    @project.design_repo = "git@github.com:acme/designs.git"
    assert_not @project.valid?
    assert_equal [ "must look like owner/name" ], @project.errors[:design_repo]
    assert_equal [ "Design repo must look like owner/name" ], @project.errors.full_messages_for(:design_repo)
  end

  # Designs pushes a branch per task and merges approvals into master: pointed
  # at the app's own repository, it would change the client's application.
  test "the design repo must be a different repository from the app's" do
    @project.github_repo = "acme/app"
    [ "acme/app", "Acme/App", "https://github.com/acme/app.git" ].each do |same|
      @project.design_repo = same
      assert_not @project.valid?, same
      assert_equal [ "must be a different repository from the app's" ], @project.errors[:design_repo], same
    end

    @project.github_repo = "https://github.com/acme/app"
    @project.design_repo = "acme/app"
    assert_not @project.valid?, "the app repo written as a URL is still the app repo"

    @project.design_repo = "acme/app-designs"
    assert @project.valid?
    @project.github_repo = nil
    @project.design_repo = "acme/app"
    assert @project.valid?, "a project with no app repo can use any design repo"
  end

  # The setup form names the app's repositories as read-only sources: one of
  # them as the target would have the AI commit designs into the application.
  test "the design repo is none of the app repositories the setup reads" do
    @project.github_repo = nil
    @project.design_app_repos = [ { "role" => "Frontend", "repo" => "acme/web@production" }, { "role" => "API", "repo" => "acme/api" } ]

    [ "acme/web", "Acme/API" ].each do |same|
      @project.design_repo = same
      assert_not @project.valid?, same
      assert_equal [ "must be a different repository from the app's" ], @project.errors[:design_repo], same
    end

    @project.design_repo = "acme/web-designs"
    assert @project.valid?
  end

  # GitHub's own limits: an owner of 39 characters, a name of 100.
  test "the design repo is at most 140 characters" do
    @project.design_repo = "#{"o" * 39}/#{"n" * 100}"
    assert @project.valid?
    @project.design_repo = "#{"o" * 40}/#{"n" * 100}"
    assert_not @project.valid?
    assert_equal [ "is too long (maximum is 140 characters)" ], @project.errors[:design_repo]
  end

  # What gets pasted is what the address bar shows.
  test "a pasted GitHub address is reduced to owner/name" do
    {
      "https://github.com/acme/designs" => "acme/designs",
      "https://github.com/acme/designs.git" => "acme/designs",
      "https://github.com/acme/designs/" => "acme/designs",
      "https://github.com/acme/designs.git/" => "acme/designs",
      "  acme/designs.git  " => "acme/designs",
      "acme/designs/" => "acme/designs",
      "HTTPS://GitHub.com/acme/designs" => "acme/designs",
      "acme/designs" => "acme/designs",
      # Only a trailing .git is dropped; dots inside a name are the name.
      "acme/designs.github.io" => "acme/designs.github.io",
      "acme/my.designs" => "acme/my.designs"
    }.each do |pasted, saved|
      @project.design_repo = pasted
      assert_equal saved, @project.design_repo, pasted
      assert @project.valid?, "#{pasted} should be accepted"
    end
  end

  test "the reduced address is what is stored" do
    @project.update!(design_repo: "https://github.com/acme/designs.git")
    assert_equal "acme/designs", @project.reload.design_repo
  end

  test "an address that is not a GitHub repository is left for the format to refuse" do
    [
      "https://gitlab.com/acme/designs", "http://github.com/acme/designs", "git@github.com:acme/designs.git",
      "https://github.com/acme", "https://github.com/acme/designs/tree/main", "acme", "acme/designs extra"
    ].each do |address|
      @project.design_repo = address
      assert_not @project.valid?, "#{address} should be refused"
    end
  end

  test "an empty design repo stays empty, and none stays none" do
    [ "   ", "https://github.com/", "/" ].each do |empty|
      @project.design_repo = empty
      assert_equal "", @project.design_repo, empty.inspect
      assert @project.valid?
    end
    @project.design_repo = nil
    assert_nil @project.design_repo
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

  test "designs_ready? needs Designs on and its repo set up" do
    project = projects(:jira_project)
    project.update_columns(designs_enabled: true, design_repo_status: "ready")
    assert project.designs_ready?
    project.update_columns(design_repo_status: "initializing")
    assert_not project.designs_ready?
    project.update_columns(design_repo_status: "ready", designs_enabled: false)
    assert_not project.designs_ready?
  end
end
