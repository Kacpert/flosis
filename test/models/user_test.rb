require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  # ---- workspace_client role -------------------------------------------
  # Full Workshop access WITH pricing, and cannot manage users. Time & HR is off
  # by default, but an admin can switch it on for a client who also logs hours.

  def workspace_client_user(workspace, time_hr_access: false)
    user = User.create!(name: "WC", email_address: "wc@example.com", password: "password12")
    WorkspaceMembership.create!(user: user, workspace: workspace, role: "workspace_client",
                               time_hr_access: time_hr_access, workshop_access: false)
    user
  end

  test "workspace_client has Workshop access and no Time & HR by default" do
    ws = workspaces(:one)
    user = workspace_client_user(ws)

    assert user.can_access_workshop?(ws), "workspace_client must have full Workshop access"
    refute user.can_access_time_hr?(ws), "Time & HR must be off until an admin grants it"
    assert_equal [ :workshop ], user.accessible_products(ws)
    refute user.time_hr_member?(ws)
  end

  test "workspace_client granted Time & HR may use it like an employee" do
    ws = workspaces(:one)
    user = workspace_client_user(ws, time_hr_access: true)

    assert user.can_access_time_hr?(ws)
    assert user.time_hr_member?(ws), "granting the product must also open the employee surfaces"
  end

  # The Workshop is why this role has an account at all, so it stays the landing
  # product even once Time & HR is added.
  test "workspace_client keeps Workshop as the default product" do
    ws = workspaces(:one)
    user = workspace_client_user(ws, time_hr_access: true)

    assert_equal [ :workshop, :time_hr ], user.accessible_products(ws)
    assert_equal :workshop, user.default_product(ws)
  end

  # The Jira-Tasks-only client role is NOT affected by any of this.
  test "the Jira-only client role never gets Time & HR, flag or not" do
    ws = workspaces(:one)
    user = users(:client_user)
    user.membership_for(ws).update!(time_hr_access: true)

    refute user.can_access_time_hr?(ws), "the Jira-only client role stays out of Time & HR"
    refute user.time_hr_member?(ws)
  end

  # A workspace_client is the Product Owner on the client side: full Workshop
  # access. Leaving them out of this predicate 403'd them out of the Jira Tasks
  # surface — including the AI chat, which then rendered as an empty panel.
  test "workspace_client counts as someone who works on tickets" do
    workspace = workspaces(:one)

    assert users(:workspace_client_user).client_or_employee?(workspace)
    assert users(:client_user).client_or_employee?(workspace), "the Jira-only client too"
    assert users(:one).client_or_employee?(workspace), "and employees and up"
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
