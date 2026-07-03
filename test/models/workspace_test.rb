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

  test "estimation_field_names defaults to AI estimation when nil" do
    w = Workspace.create!(name: "Estimation Co")
    assert_equal ["AI estimation"], w.estimation_field_names
  end

  test "estimation_field_names returns the stored value when present" do
    w = Workspace.create!(name: "Estimation Co", estimation_field_names: ["Custom field"])
    assert_equal ["Custom field"], w.estimation_field_names
  end

  test "estimation_trigger defaults to manual" do
    w = Workspace.create!(name: "Estimation Co")
    assert_equal "manual", w.estimation_trigger
  end

  test "estimation_status_trigger defaults to Ready for dev" do
    w = Workspace.create!(name: "Estimation Co")
    assert_equal "Ready for dev", w.estimation_status_trigger
  end
end
