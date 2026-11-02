require "test_helper"

class WorkspaceInviteTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  test "an address without an account gets one, a membership and the welcome email" do
    invite = WorkspaceInvite.new(workspaces(:two), name: "Jane Doe", email_address: " Jane@Acme.com ", workspace_admin: true)

    assert_difference -> { User.count } => 1, -> { WorkspaceMembership.count } => 1 do
      assert invite.save
    end
    invite.deliver_later

    user = User.find_by!(email_address: "jane@acme.com")
    assert_equal "Jane Doe", user.name
    assert user.workspace_admin?(workspaces(:two))
    assert_enqueued_email_with InvitationMailer, :welcome, args: [ user, workspaces(:two) ]
  end

  test "an address with an account is added as it is and gets the added-to email" do
    invite = WorkspaceInvite.new(workspaces(:two), name: "Someone Else", email_address: users(:two).email_address)

    assert_no_difference -> { User.count } do
      assert invite.save
    end
    invite.deliver_later

    assert_equal "Other User", users(:two).reload.name
    assert users(:two).member_of?(workspaces(:two))
    assert_enqueued_email_with InvitationMailer, :added_to_workspace, args: [ users(:two), workspaces(:two) ]
  end

  test "someone already in the workspace is refused" do
    invite = WorkspaceInvite.new(workspaces(:one), name: "", email_address: users(:two).email_address)

    assert_not invite.save
    assert_includes invite.errors.full_messages.to_sentence, "already a member"
  end

  test "a bad address leaves nothing behind" do
    invite = WorkspaceInvite.new(workspaces(:two), name: "Jane", email_address: "not-an-address")

    assert_no_difference [ "User.count", "WorkspaceMembership.count" ] do
      assert_not invite.save
    end
    assert_includes invite.errors.full_messages.to_sentence, "Email address is invalid"
  end
end
