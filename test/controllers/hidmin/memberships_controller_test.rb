require "test_helper"

class Hidmin::MembershipsControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
    @workspace = workspaces(:one)
  end

  test "a person is added by email" do
    assert_difference -> { @workspace.workspace_memberships.count } => 1 do
      post hidmin_workspace_memberships_path(@workspace),
           params: { name: "New Person", email_address: "new@example.com", workspace_admin: "1", time_hr_access: "1" }
    end

    person = User.find_by!(email_address: "new@example.com")
    assert_redirected_to hidmin_workspace_path(@workspace)
    assert person.workspace_admin?(@workspace)
    assert person.can_access_time_hr?(@workspace)
    assert_enqueued_email_with InvitationMailer, :welcome, args: [ person, @workspace ]
  end

  test "someone already a member is refused with a reason" do
    assert_no_difference -> { WorkspaceMembership.count } do
      post hidmin_workspace_memberships_path(@workspace), params: { name: "", email_address: users(:two).email_address }
    end

    assert_redirected_to hidmin_workspace_path(@workspace)
    assert_match "already a member", flash[:alert]
  end

  test "admin can be granted and taken away, but not from the last administrator" do
    membership = workspace_memberships(:two_employee)
    patch hidmin_workspace_membership_path(@workspace, membership), params: { workspace_admin: "1" }
    assert membership.reload.workspace_admin?

    patch hidmin_workspace_membership_path(@workspace, membership), params: { workspace_admin: "0" }
    assert_not membership.reload.workspace_admin?

    owner = workspace_memberships(:one_owner)
    patch hidmin_workspace_membership_path(@workspace, owner), params: { workspace_admin: "0" }
    assert owner.reload.workspace_admin?
    assert_match "at least one administrator", flash[:alert]
  end

  test "a person is removed, but never the last administrator" do
    assert_difference -> { WorkspaceMembership.count } => -1 do
      delete hidmin_workspace_membership_path(@workspace, workspace_memberships(:two_employee))
    end

    assert_no_difference -> { WorkspaceMembership.count } do
      delete hidmin_workspace_membership_path(@workspace, workspace_memberships(:one_owner))
    end
    assert_match "at least one administrator", flash[:alert]
  end

  test "the invitation is sent again" do
    post resend_invitation_hidmin_workspace_membership_path(@workspace, workspace_memberships(:two_employee))

    assert_redirected_to hidmin_workspace_path(@workspace)
    assert_enqueued_email_with InvitationMailer, :welcome, args: [ users(:two), @workspace ]
  end

  test "a membership of another organization cannot be reached through this one" do
    other = WorkspaceMembership.create!(workspace: workspaces(:two), user: users(:two))

    delete hidmin_workspace_membership_path(@workspace, other)
    assert_response :not_found
    assert WorkspaceMembership.exists?(other.id)
  end
end
