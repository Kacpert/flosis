require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  # ---- workspace_client (a Product Owner who logs their own hours) ------
  # Full Workshop access WITH pricing, and cannot manage users. Time & HR is off
  # by default, but an admin can switch it on for a client who also logs hours.
  # The `role` column stays until Task 18, but nothing in the app reads it any
  # more — Task 9 removed the role-based predicates. It is set here only for
  # fixture-shape parity with the seeded workspace_client_membership fixture.

  # Workshop access is now "has at least one project" (Task 5), not a role or a
  # flag, so this workspace_client fixture needs a real ProjectMembership to
  # have anywhere to work — never the retired workshop_access flag.
  def workspace_client_user(workspace, time_hr_access: false)
    user = User.create!(name: "WC", email_address: "wc@example.com", password: "password12")
    WorkspaceMembership.create!(user: user, workspace: workspace, time_hr_access: time_hr_access)
    ProjectMembership.create!(user: user, project: workspace.projects.first)
    user
  end

  test "workspace_client has Workshop access and no Time & HR by default" do
    ws = workspaces(:one)
    user = workspace_client_user(ws)

    assert user.can_access_workshop?(ws), "workspace_client must have full Workshop access"
    refute user.can_access_time_hr?(ws), "Time & HR must be off until an admin grants it"
    assert_equal [ :workshop ], user.accessible_products(ws)
  end

  test "workspace_client granted Time & HR gains the product" do
    ws = workspaces(:one)
    user = workspace_client_user(ws, time_hr_access: true)

    assert user.can_access_time_hr?(ws)
  end

  # Task 5 dropped the role-based reordering: accessible_products now always
  # lists Time & HR before Workshop when both are open, and the host (not the
  # role) is what lands app.flosis.com on the Workshop instead.
  test "workspace_client with both accesses lists Time & HR before Workshop" do
    ws = workspaces(:one)
    user = workspace_client_user(ws, time_hr_access: true)

    assert_equal [ :time_hr, :workshop ], user.accessible_products(ws)
    assert_equal :time_hr, user.default_product(ws)
  end

  # Task 5 made can_access_time_hr? read the raw flag alone, with no more
  # client_role? special-case — production data forces the flag off for every
  # client via the backfill migration's revoke_hr, so the guard is redundant
  # there.
  test "the Jira-only client's Time & HR access reads the raw flag" do
    ws = workspaces(:one)
    user = users(:client_user)
    user.membership_for(ws).update!(time_hr_access: true)

    assert user.can_access_time_hr?(ws), "the flag alone now governs can_access_time_hr?"
  end
end
