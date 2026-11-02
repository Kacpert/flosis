require "test_helper"

class Hidmin::WorkspacesControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
  end

  test "creating an organization makes its first administrator and emails them" do
    assert_difference -> { Workspace.count } => 1, -> { User.count } => 1 do
      post hidmin_workspaces_path, params: {
        workspace: { name: "Acme", workshop_enabled: "1", clients_enabled: "0" },
        admin: { name: "Jane Doe", email_address: "jane@acme.com", time_hr_access: "0" }
      }
    end

    workspace = Workspace.find_by!(name: "Acme")
    jane = User.find_by!(email_address: "jane@acme.com")
    assert_redirected_to hidmin_workspace_path(workspace)
    assert workspace.workshop_enabled?
    assert_not workspace.hr_access?, "a new organization starts without Time & HR"
    assert jane.workspace_admin?(workspace)
    assert_not jane.can_access_time_hr?(workspace)
    assert_enqueued_email_with InvitationMailer, :welcome, args: [ jane, workspace ]
  end

  test "an existing account can be made the administrator of a new organization" do
    post hidmin_workspaces_path, params: {
      workspace: { name: "Acme" }, admin: { name: "", email_address: users(:two).email_address }
    }

    workspace = Workspace.find_by!(name: "Acme")
    assert users(:two).workspace_admin?(workspace)
    assert_enqueued_email_with InvitationMailer, :added_to_workspace, args: [ users(:two), workspace ]
  end

  test "a bad administrator address creates no organization" do
    assert_no_difference [ "Workspace.count", "User.count", "WorkspaceMembership.count" ] do
      post hidmin_workspaces_path, params: { workspace: { name: "Acme" }, admin: { name: "Jane", email_address: "nope" } }
    end

    assert_response :unprocessable_entity
    assert_no_enqueued_emails
  end

  test "a blank name creates nothing either" do
    assert_no_difference [ "Workspace.count", "User.count" ] do
      post hidmin_workspaces_path, params: { workspace: { name: "" }, admin: { name: "Jane", email_address: "jane@acme.com" } }
    end

    assert_response :unprocessable_entity
  end

  test "settings are saved" do
    patch hidmin_workspace_path(workspaces(:two)),
          params: { workspace: { name: "Renamed", workshop_enabled: "1", hr_access: "0", clients_enabled: "1" } }

    assert_redirected_to hidmin_workspace_path(workspaces(:two))
    workspaces(:two).reload
    assert_equal "Renamed", workspaces(:two).name
    assert workspaces(:two).workshop_enabled?
    assert_not workspaces(:two).hr_access?
    assert workspaces(:two).clients_enabled?
  end

  test "an organization's Time & HR can be switched on" do
    workspaces(:two).update!(hr_access: false)

    patch hidmin_workspace_path(workspaces(:two)), params: { workspace: { hr_access: "1" } }

    assert workspaces(:two).reload.hr_access?
  end
end
