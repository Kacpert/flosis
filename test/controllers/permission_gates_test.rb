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

  test "Tasks opens the Jira board and its absence closes it" do
    with_permissions("Project Manager")
    get jira_tasks_path
    assert_response :success

    @membership.update!(tasks: false)
    get jira_tasks_path
    # require_permission! denies via product_landing_path, not root_path — this
    # user keeps time_hr_access: true from setup, so the deny sends them to the
    # product they still have (Time & HR), not to "/".
    assert_redirected_to time_entries_path
  end

  # The picker is a member route on projects, so its helper takes the project.
  # An employee who logs hours but was never given Workshop work still needs it.
  test "the timer's Jira task picker survives without the Tasks permission" do
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false))

    get jira_tasks_project_path(@project)

    assert_response :success
  end
end
