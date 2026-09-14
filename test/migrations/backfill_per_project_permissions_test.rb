require "test_helper"
require Rails.root.join("db/migrate/20260912121000_backfill_per_project_permissions")

# The backfill is the only part of this work that touches live data, so it gets
# a test rather than a careful read. Deleted in Task 18 along with the columns
# it reads.
class BackfillPerProjectPermissionsTest < ActiveSupport::TestCase
  # The `two_employee` fixture ships with `workshop_access: false`. Most cases
  # here want the employee who DID have Workshop access, so turn it on in setup
  # and let the one case that tests the other branch turn it back off.
  setup do
    workspace_memberships(:two_employee).update_columns(workshop_access: true)
    ProjectMembership.update_all(PermissionPreset::PERMISSIONS.index_with(false))
    WorkspaceMembership.update_all(workspace_admin: false)
    BackfillPerProjectPermissions.new.up
  end

  test "an owner becomes a workspace admin and gains no new rows" do
    assert workspace_memberships(:one_owner).reload.workspace_admin
    assert_nil ProjectMembership.find_by(user: users(:one), project: projects(:other_jira_project))
  end

  test "an owner's existing rows read as Administrator" do
    assert_equal "Administrator", project_memberships(:one_elvium).reload.role_label
  end

  test "an employee with Workshop access becomes a Project Manager" do
    assert_equal "Project Manager", project_memberships(:two_elvium).reload.role_label
  end

  test "an employee without Workshop access gets no permissions" do
    workspace_memberships(:two_employee).update_columns(workshop_access: false)
    ProjectMembership.update_all(PermissionPreset::PERMISSIONS.index_with(false))
    WorkspaceMembership.update_all(workspace_admin: false)

    BackfillPerProjectPermissions.new.up

    assert_equal [], project_memberships(:two_elvium).reload.granted
  end

  test "a workspace_client becomes a Product Owner" do
    assert_equal "Product Owner", project_memberships(:workspace_client_elvium).reload.role_label
  end

  test "a client keeps Tasks only and loses HR" do
    workspace_memberships(:client_membership).update_columns(time_hr_access: true)

    BackfillPerProjectPermissions.new.up
    membership = project_memberships(:client_elvium).reload

    assert_equal %i[tasks], membership.granted
    assert_not workspace_memberships(:client_membership).reload.time_hr_access
  end

  test "a plain admin becomes a workspace admin too" do
    workspace_memberships(:two_employee).update_columns(role: 1)

    BackfillPerProjectPermissions.new.up

    assert workspace_memberships(:two_employee).reload.workspace_admin
  end

  test "running it twice changes nothing" do
    before = ProjectMembership.order(:id).pluck(:id, *PermissionPreset::PERMISSIONS)
    before_workspace = WorkspaceMembership.order(:id).pluck(:id, :workspace_admin)

    BackfillPerProjectPermissions.new.up

    assert_equal before, ProjectMembership.order(:id).pluck(:id, *PermissionPreset::PERMISSIONS)
    assert_equal before_workspace, WorkspaceMembership.order(:id).pluck(:id, :workspace_admin)
  end
end
