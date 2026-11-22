require "test_helper"

# What an import's turn is given (Designs::Subject::SetupSubject): the git
# tool on the app's history when the project has its clones (Kacper,
# 2026-11-22), beside the browser.
class Designs::SetupSubjectTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("setup-subject")
    @project = projects(:jira_project)
    @project.update!(workspace_dir: File.join(@dir, "workspace"), design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ],
                     design_app_url: "https://staging.acme.test")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://staging.acme.test/login", username: "a", password: "p", position: 0)
    @setup = @project.design_setups.create!(kind: "resync", status: "active", phase: "feature", step: 3, started_by: users(:one))
    session = ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_setup",
                                  claude_session_id: SecureRandom.uuid, codebase_path: @dir, design_setup: @setup)
    @subject = Designs::Subject::SetupSubject.new(session)
  end

  teardown { FileUtils.remove_entry(@dir) }

  def clone!
    path = Designs::AppHistory.new(@project).path("acme/app")
    FileUtils.mkdir_p(path)
    File.write(path.join("HEAD"), "ref: refs/heads/main\n")
    path
  end

  def servers
    @subject.with_mcp(File.join(@dir, "worktree")) { |config| JSON.parse(File.read(config))["mcpServers"] }
  end

  test "a setup turn has the git tool on the app's history when the clones exist" do
    path = clone!

    git = servers["flosis_git"]
    assert git["args"].first.end_with?("git.mjs")
    assert_equal({ "acme/app" => path.to_s }, JSON.parse(git["env"]["FLOSIS_GIT_REPOS"]))
    assert_includes @subject.tools, "mcp__flosis_git__git"
    assert_includes @subject.system_text, "# The app's history"
    assert servers["flosis_browser"], "the browser stays"
  end

  test "without clones there is no git server" do
    assert_nil servers["flosis_git"]
    refute_includes @subject.tools, "mcp__flosis_git__git"
    refute_includes @subject.system_text, "# The app's history"
  end
end
