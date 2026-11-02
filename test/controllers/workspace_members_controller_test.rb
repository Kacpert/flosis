require "test_helper"

# The employee directory answers two questions and no longer pretends to
# answer a third. Whether someone is in HR, and whether they run the
# workspace. What they may do inside a project is decided in that project.
class WorkspaceMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin_membership = workspace_memberships(:one_owner)
    @admin_membership.update!(workspace_admin: true)
    sign_in_as(users(:one))
  end

  test "adding a member grants HR access and nothing in any project" do
    assert_difference "User.count", 1 do
      post workspace_members_path, params: {
        name: "New Person", email_address: "new-person@example.com", time_hr_access: "1"
      }
    end

    membership = WorkspaceMembership.joins(:user).find_by(users: { email_address: "new-person@example.com" })
    assert membership.time_hr_access
    assert_not membership.workspace_admin
    assert_equal 0, ProjectMembership.where(user: membership.user).count
  end

  test "an administrator can be promoted and demoted" do
    membership = workspace_memberships(:two_employee)

    patch workspace_member_path(membership), params: { workspace_admin: "1", time_hr_access: "1" }
    assert membership.reload.workspace_admin

    patch workspace_member_path(membership), params: { workspace_admin: "0", time_hr_access: "1" }
    assert_not membership.reload.workspace_admin
  end

  test "the last administrator cannot be demoted" do
    patch workspace_member_path(@admin_membership), params: { workspace_admin: "0", time_hr_access: "1" }

    assert @admin_membership.reload.workspace_admin, "a workspace must keep an administrator"
    assert_equal "A workspace needs at least one administrator.", flash[:alert]
  end

  test "removing an ordinary member works" do
    assert_difference "WorkspaceMembership.count", -1 do
      delete workspace_member_path(workspace_memberships(:two_employee))
    end
  end

  # Deliberately a model assertion, not a request. Through the controller the
  # sole administrator is always the signed-in user, so the "you can't remove
  # yourself" guard fires first and a request test would pass for the wrong
  # reason. The predicate is what the destroy and update guards both consult.
  test "the sole administrator knows it is the last one" do
    assert workspace_memberships(:one_owner).last_workspace_admin?

    workspace_memberships(:two_employee).update!(workspace_admin: true)

    assert_not workspace_memberships(:one_owner).reload.last_workspace_admin?
  end

  test "a membership that is not an admin is never the last one" do
    assert_not workspace_memberships(:two_employee).last_workspace_admin?
  end
end
