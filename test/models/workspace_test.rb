require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "clients feature is disabled by default for a new workspace" do
    workspace = Workspace.create!(name: "Fresh Co")
    assert_not workspace.clients_enabled?, "new workspaces should default to clients disabled"
  end

  test "github settings default to nil/false" do
    w = Workspace.create!(name: "GH Co")
    assert_nil w.github_token
    assert_nil w.github_repo
    assert_not w.pr_review_enabled
    assert_nil w.github_status_ok
  end
end
