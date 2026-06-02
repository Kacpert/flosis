require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "clients feature is disabled by default for a new workspace" do
    workspace = Workspace.create!(name: "Fresh Co")
    assert_not workspace.clients_enabled?, "new workspaces should default to clients disabled"
  end
end
