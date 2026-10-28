require "test_helper"

# Creating and switching workspaces is a workspace-wide act, and an
# admin-managed single-workspace account must not reach it. The guard used to
# read the legacy `client` role; it now asks what that role actually meant —
# no HR access and no workspace privilege anywhere.
class WorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "a restricted account cannot open the new-workspace page" do
    membership = workspace_memberships(:client_membership)
    assert_not membership.time_hr_access, "arrangement: a restricted account has no HR access"
    assert_not membership.workspace_admin, "arrangement: nor any workspace privilege"
    sign_in_as(users(:client_user))

    get new_workspace_path

    assert_redirected_to jira_tasks_path
    assert_equal "Your account is managed by an administrator.", flash[:alert]
  end

  test "a restricted account cannot switch workspaces either" do
    sign_in_as(users(:client_user))

    post switch_workspace_path(workspaces(:one))

    assert_redirected_to jira_tasks_path
  end

  test "an ordinary member reaches the new-workspace page" do
    sign_in_as(users(:one))

    get new_workspace_path

    assert_response :success
  end

  # The privilege alone is enough, without HR — an administrator who does not
  # log hours still manages workspaces.
  test "a workspace administrator without HR access is not restricted" do
    workspace_memberships(:client_membership).update!(workspace_admin: true)
    sign_in_as(users(:client_user))

    get new_workspace_path

    assert_response :success
  end

  # And HR access alone is enough, without the privilege: an ordinary employee
  # is not an admin-managed account.
  test "an employee with HR access but no privilege is not restricted" do
    workspace_memberships(:client_membership).update!(time_hr_access: true)
    sign_in_as(users(:client_user))

    get new_workspace_path

    assert_response :success
  end
end
