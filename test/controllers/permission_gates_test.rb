require "test_helper"

# One request per gate family, asserting the refusal as well as the pass.
# Sixty files used to decide access for themselves; these pin down the handful
# of gates that now decide it for them.
class PermissionGatesTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    @user = users(:two)
    workspace_memberships(:two_employee).update!(workspace_admin: false, time_hr_access: true)
    @membership = project_memberships(:two_elvium)
    sign_in_as(@user)
  end

  def with_permissions(preset)
    @membership.update!(PermissionPreset.attributes_for(preset))
  end

  # The Workshop-route cases live in Task 6 and the Configuration-tab cases in
  # Task 8 — each is added by the task that makes it pass, so no task commits a
  # red test.

  test "the workspace privilege opens the HR member directory" do
    with_permissions("Project Manager")
    get workspace_members_path
    assert_redirected_to root_path

    workspace_memberships(:two_employee).update!(workspace_admin: true)
    get workspace_members_path
    assert_response :success
  end

  test "HR access alone opens the timesheet" do
    with_permissions("Project Manager")
    get timesheet_path
    assert_response :success

    workspace_memberships(:two_employee).update!(time_hr_access: false)
    get timesheet_path
    assert_response :redirect
  end

end
