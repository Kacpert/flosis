require "test_helper"

# A workspace_client is normally Workshop-only. When an admin ticks their
# "Time & HR" product access, they additionally get to use Time & HR the way an
# employee does — primarily to log their own hours. Before this, the checkbox
# was shown in the member form but had no effect: can_access_time_hr? blocked
# the role outright, so ticking it changed nothing.
#
# What must NOT change: they still only see their OWN hours, can only log
# against projects they're a member of, and the reports stay admin-only.
class WorkspaceClientTimeHrTest < ActionDispatch::IntegrationTest
  setup do
    @member = workspace_memberships(:workspace_client_membership)
    @user = users(:workspace_client_user)
    @project = projects(:jira_project)     # they are a member
    @other = projects(:other_jira_project) # they are NOT a member
    sign_in_as(@user)
  end

  # --- with Time & HR access (the new behaviour) ----------------------------

  test "can open time entries" do
    get time_entries_path
    assert_response :success
  end

  test "can open the timesheet" do
    get timesheet_path
    assert_response :success
  end

  test "can log an hour against a project they belong to" do
    assert_difference -> { @user.time_entries.count }, 1 do
      post time_entries_path, params: { time_entry: {
        project_id: @project.id,
        description: "Reviewing the spec",
        started_at: Time.current.change(hour: 9),
        stopped_at: Time.current.change(hour: 10)
      } }
    end
  end

  test "can start and stop a timer" do
    post start_timer_path, params: { project_id: @project.id, description: "Working" }
    assert @user.time_entries.where(stopped_at: nil).exists?,
      "expected a running timer for the workspace client"
  end

  test "can reach tags" do
    get tags_path
    assert_response :success
  end

  test "can reach holidays" do
    get holiday_requests_path
    assert_response :success
  end

  # --- scoping still holds --------------------------------------------------

  test "only their own hours show on the timesheet" do
    somebody_else = users(:two)
    monday = Date.current.beginning_of_week(:monday)
    workspaces(:one).time_entries.create!(
      user: somebody_else, project: @project,
      description: "SomebodyElsesSecretWork",
      started_at: monday.to_time.change(hour: 9),
      stopped_at: monday.to_time.change(hour: 10)
    )

    get timesheet_path
    assert_response :success
    assert_no_match(/SomebodyElsesSecretWork/, @response.body,
      "another user's time entry leaked into the workspace client's timesheet")
  end

  test "cannot log time against a project they are not a member of" do
    get new_time_entry_path
    assert_response :success
    assert_select "option[value=?]", @other.id.to_s, count: 0
  end

  test "reports stay admin-only" do
    get reports_summary_path
    assert_redirected_to root_path
  end

  # --- product landing ------------------------------------------------------

  test "workshop stays the default product" do
    assert_equal :workshop, @user.default_product(workspaces(:one)),
      "a workspace client's primary reason for an account is the Workshop"
  end

  # --- opt-in, not opt-out --------------------------------------------------

  # time_hr_access defaults to true at the schema level (right for employees).
  # Before this feature the role blocked Time & HR outright, so that default was
  # harmless for a workspace_client; now it would silently hand every newly
  # added one the whole product. It has to be off until an admin ticks it.
  test "a newly added workspace client starts without Time & HR" do
    sign_in_as(users(:one)) # an owner may add members

    assert_difference -> { WorkspaceMembership.count }, 1 do
      post workspace_members_path, params: {
        email_address: "brand-new-client@example.com",
        name: "Brand New Client",
        role: "workspace_client"
      }
    end

    membership = WorkspaceMembership.order(:created_at).last
    assert_equal "workspace_client", membership.role
    assert_not membership.time_hr_access,
      "a new workspace client was given Time & HR without anyone asking for it"
  end

  test "a newly added employee still gets Time & HR by default" do
    sign_in_as(users(:one))

    post workspace_members_path, params: {
      email_address: "brand-new-employee@example.com",
      name: "Brand New Employee",
      role: "employee"
    }

    membership = WorkspaceMembership.order(:created_at).last
    assert_equal "employee", membership.role
    assert membership.time_hr_access, "employees are Time & HR users by default"
  end

  # --- without Time & HR access (unchanged behaviour) ------------------------

  test "time entries stay closed when the product access is off" do
    @member.update!(time_hr_access: false)

    get time_entries_path
    assert_response :redirect
    assert_not_equal time_entries_path, @response.redirect_url,
      "expected to be redirected AWAY from time entries"
  end

  test "the timer stays closed when the product access is off" do
    @member.update!(time_hr_access: false)

    assert_no_difference -> { @user.time_entries.count } do
      post start_timer_path, params: { project_id: @project.id }
    end
  end
end
