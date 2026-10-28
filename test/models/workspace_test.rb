require "test_helper"
require Rails.root.join("db/migrate/20260913120000_drop_legacy_role_columns")

# What is left on a workspace once the role and the copied project
# configuration are gone. The estimation cases moved to
# ProjectEstimationSettingsTest, against the model that owns those columns now.
class WorkspaceTest < ActiveSupport::TestCase
  test "clients feature is disabled by default for a new workspace" do
    workspace = Workspace.create!(name: "Fresh Co")
    assert_not workspace.clients_enabled?, "new workspaces should default to clients disabled"
  end

  # The guard for the release that dropped them: a reader left behind on the
  # workspace raises in production, where these columns no longer exist.
  test "the workspace carries no copy of the project configuration" do
    gone = DropLegacyRoleColumns::WORKSPACE_COLUMNS.map(&:to_s)

    assert_empty gone & Workspace.column_names, "a dropped column came back onto workspaces"
  end

  test "a membership carries no workspace-wide role" do
    gone = DropLegacyRoleColumns::MEMBERSHIP_COLUMNS.map(&:to_s)

    assert_empty gone & WorkspaceMembership.column_names
  end
end
