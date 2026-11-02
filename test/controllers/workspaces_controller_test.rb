require "test_helper"

# Creating a workspace is a workspace-wide act, and an admin-managed account
# must not reach it. The guard used to read the legacy `client` role; it now
# asks what that role actually meant — no HR access and no workspace privilege
# anywhere. Switching is open to everyone, between their own workspaces.
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

  # Time & HR held in an organization that doesn't have it is no HR access.
  test "HR access in an organization without Time & HR does not lift the restriction" do
    workspace_memberships(:client_membership).update!(time_hr_access: true)
    workspaces(:one).update!(hr_access: false)
    sign_in_as(users(:client_user))

    get new_workspace_path

    assert_redirected_to jira_tasks_path
  end

  test "a restricted account switches between the workspaces it belongs to" do
    WorkspaceMembership.create!(user: users(:client_user), workspace: workspaces(:two), time_hr_access: false)
    sign_in_as(users(:client_user))

    post switch_workspace_path(workspaces(:two))

    assert_redirected_to root_path
    assert_equal workspaces(:two).id, session[:workspace_id]
  end

  test "switching from the Workshop lands in the Workshop where the person has it" do
    WorkspaceMembership.create!(user: users(:one), workspace: workspaces(:two), workspace_admin: true)
    sign_in_as(users(:one))

    post switch_workspace_path(workspaces(:two)), params: { product: "workshop" }

    assert_equal "workshop", session[:product]
    post switch_workspace_path(workspaces(:one)), params: { product: "nonsense" }
    assert_equal "workshop", session[:product]
  end

  test "nobody switches into a workspace they don't belong to" do
    sign_in_as(users(:client_user))

    post switch_workspace_path(workspaces(:two))

    assert_response :not_found
    assert_not_equal workspaces(:two).id, session[:workspace_id]
  end

  test "the Flosis account menu offers the person's other workspaces" do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: projects(:jira_project).id }

    get workshop_pipeline_path
    assert_select "form[action=?]", switch_workspace_path(workspaces(:two)), count: 0

    WorkspaceMembership.create!(user: users(:one), workspace: workspaces(:two))
    get workshop_pipeline_path
    assert_select "form[action=?] button", switch_workspace_path(workspaces(:two)), text: "Switch to Other Workspace"
    assert_select "form[action=?]", switch_workspace_path(workspaces(:one)), count: 0
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
