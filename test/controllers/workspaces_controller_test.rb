require "test_helper"

# Creating and switching workspaces is a workspace-wide act, and an
# admin-managed single-workspace account must not reach it. The guard is
# `block_clients`, which still reads the legacy role; Task 18 replaces it, so
# this file exists to give that replacement something to keep green.
class WorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "a client account cannot open the new-workspace page" do
    sign_in_as(users(:client_user))

    get new_workspace_path

    assert_redirected_to jira_tasks_path
    assert_equal "Clients can't manage workspaces.", flash[:alert]
  end

  test "an ordinary member reaches the new-workspace page" do
    sign_in_as(users(:one))

    get new_workspace_path

    assert_response :success
  end
end
