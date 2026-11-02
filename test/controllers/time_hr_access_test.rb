require "test_helper"

# Access to the Time & HR working surfaces (time entries, the timer, the
# timesheet, tags, holidays) is decided by two independent facts about the
# person, not by role:
#
#   - `time_hr_access` on their WorkspaceMembership
#   - a `ProjectMembership` on the project they want to book time against
#
# Nothing here is a Workshop/permission concept — that separation is the
# point, and this file is where it gets proved.
#
# Recovers coverage that lived in the now-deleted
# test/controllers/workspace_client_time_hr_test.rb, which exercised the same
# surfaces through a `workspace_client` role that no longer exists.
class TimeHrAccessTest < ActionDispatch::IntegrationTest
  setup do
    @membership = workspace_memberships(:two_employee)
    @user = users(:two)
    @project = projects(:jira_project)       # ProjectMembership two_elvium
    @other = projects(:other_jira_project)   # no ProjectMembership for @user
    assert @membership.time_hr_access
    sign_in_as(@user)
  end

  test "posting a time entry" do
    assert_difference -> { @user.time_entries.count }, 1 do
      post time_entries_path, params: { time_entry: {
        project_id: @project.id,
        description: "Reviewing the spec",
        started_at: Time.current.change(hour: 9),
        stopped_at: Time.current.change(hour: 10)
      } }
    end

    @membership.update!(time_hr_access: false)

    assert_no_difference -> { @user.time_entries.count } do
      post time_entries_path, params: { time_entry: {
        project_id: @project.id,
        description: "Sneaking one in",
        started_at: Time.current.change(hour: 11),
        stopped_at: Time.current.change(hour: 12)
      } }
    end
    assert_response :redirect
  end

  test "opening the timesheet" do
    get timesheet_path
    assert_response :success

    @membership.update!(time_hr_access: false)

    get timesheet_path
    assert_response :redirect
  end

  test "starting and stopping a timer" do
    post start_timer_path, params: { project_id: @project.id, description: "Working" }
    assert @user.time_entries.where(stopped_at: nil).exists?,
      "expected a running timer"

    patch stop_timer_path
    assert_not @user.time_entries.where(stopped_at: nil).exists?,
      "expected the timer to have stopped"

    @membership.update!(time_hr_access: false)

    assert_no_difference -> { @user.time_entries.count } do
      post start_timer_path, params: { project_id: @project.id, description: "Sneaking one in" }
    end
    assert_response :redirect
  end

  test "reaching tags" do
    get tags_path
    assert_response :success

    @membership.update!(time_hr_access: false)

    get tags_path
    assert_response :redirect
  end

  test "reaching holidays" do
    get holiday_requests_path
    assert_response :success

    @membership.update!(time_hr_access: false)

    get holiday_requests_path
    assert_response :redirect
  end

  # --- scoping: own hours only -----------------------------------------------

  test "only their own hours show on the timesheet" do
    monday = Date.current.beginning_of_week(:monday)
    workspaces(:one).time_entries.create!(
      user: @user, project: @project,
      description: "MyOwnWork",
      started_at: monday.to_time.change(hour: 9),
      stopped_at: monday.to_time.change(hour: 10)
    )
    workspaces(:one).time_entries.create!(
      user: users(:one), project: @project,
      description: "SomebodyElsesSecretWork",
      started_at: monday.to_time.change(hour: 9),
      stopped_at: monday.to_time.change(hour: 10)
    )

    get timesheet_path
    assert_response :success
    assert_match(/MyOwnWork/, @response.body)
    assert_no_match(/SomebodyElsesSecretWork/, @response.body,
      "another user's time entry leaked into the timesheet")
  end

  # --- scoping: no ProjectMembership on the other project --------------------

  test "cannot book time against a project they are not a member of" do
    get new_time_entry_path
    assert_response :success
    # Scoped to the entry form's own project select, not the timer bar's
    # (rendered in the layout on every page, also driven by available_projects).
    assert_select "select#time_entry_project_id" do
      assert_select "option[value=?]", @project.id.to_s, count: 1
      assert_select "option[value=?]", @other.id.to_s, count: 0
    end
  end
end
