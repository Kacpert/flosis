require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  # ---- workspace_client role -------------------------------------------
  # Full Workshop access WITH pricing, but NO Time & HR, and cannot manage users.

  def workspace_client_user(workspace)
    user = User.create!(name: "WC", email_address: "wc@example.com", password: "password12")
    WorkspaceMembership.create!(user: user, workspace: workspace, role: "workspace_client",
                               time_hr_access: true, workshop_access: false)
    user
  end

  test "workspace_client has Workshop access but NOT Time & HR (even if time_hr_access flag is set)" do
    ws = workspaces(:one)
    user = workspace_client_user(ws)

    assert user.can_access_workshop?(ws), "workspace_client must have full Workshop access"
    refute user.can_access_time_hr?(ws), "workspace_client must NOT have Time & HR access"
    assert_equal [ :workshop ], user.accessible_products(ws)
  end

  test "workspace_client sees pricing" do
    ws = workspaces(:one)
    user = workspace_client_user(ws)
    assert user.can_see_money?(ws), "workspace_client sees pricing"
  end

  test "workspace_client is distinct from the Jira-only client role" do
    ws = workspaces(:one)
    user = workspace_client_user(ws)
    assert user.workspace_client_role?(ws)
    refute user.client_role?(ws)
    # And Workshop access does NOT depend on the workshop_access flag for this role.
    refute user.membership_for(ws).workshop_access
    assert user.can_access_workshop?(ws)
  end
end
