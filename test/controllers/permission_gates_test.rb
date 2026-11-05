require "test_helper"
require "webmock/minitest"

# One request per gate family, asserting the refusal as well as the pass.
# Sixty files used to decide access for themselves; these pin down the handful
# of gates that now decide it for them.
class PermissionGatesTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    @user = users(:two)
    workspace_memberships(:two_employee).update!(workspace_admin: false, time_hr_access: true)
    @membership = project_memberships(:two_elvium)
    # workshop_enabled defaults to false — irrelevant to the HR/Jira-board
    # cases above (neither goes through Workshop::BaseController's
    # require_workshop!), but the Workshop-route cases below do.
    workspaces(:one).update!(workshop_enabled: true)
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
    # require_permission! denies via workshop_landing_path, which stays inside
    # Workshop and picks the best page this person can still open — Project
    # Manager also grants Automations, so that's workshop_process_path, not
    # Time & HR and not root_path.
    assert_redirected_to workshop_process_path
  end

  # The picker is a member route on projects, so its helper takes the project.
  # An employee who logs hours but was never given Workshop work still needs it.
  test "the timer's Jira task picker survives without the Tasks permission" do
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false))

    get jira_tasks_project_path(@project)

    assert_response :success
  end

  test "someone without Tasks is not bounced between pages forever" do
    @membership.update!(PermissionPreset.attributes_for("Project Manager").merge(tasks: false))

    get workshop_pipeline_path
    follow_redirect!

    assert_response :success, "the deny target must be a page this person can actually open"
  end

  test "someone holding only Automations reaches the automations page" do
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false).merge(automations: true))

    get workshop_process_path

    assert_response :success
  end

  # Configuration is per-project. Holding it on the session's current project
  # (jira_project) must not grant it on a different project (SecretProject)
  # reached via params — the three sites below all resolve their target
  # project from params, not from current_workshop_project.
  def grant_configuration_here_tasks_there
    @membership.update!(PermissionPreset.attributes_for("Administrator"))
    other = projects(:other_jira_project)
    ProjectMembership.create!(user: @user, project: other,
                               **PermissionPreset.attributes_for("Project Manager"))
    other
  end

  test "Configuration on one project is not Configuration on another (jira_tasks#refresh)" do
    other = grant_configuration_here_tasks_there

    post refresh_jira_tasks_path(project_id: other.id)

    assert_response :redirect
    assert_not_equal "Jira sync complete.", flash[:notice]
  end

  test "Configuration on one project is not Configuration on another (jira#sync)" do
    other = grant_configuration_here_tasks_there

    post jira_sync_project_path(other)

    assert_response :redirect
    assert_not_equal "Jira sync complete.", flash[:notice]
  end

  test "Configuration on one project is not Configuration on another (task_breakdowns#update_jira)" do
    other = grant_configuration_here_tasks_there
    task = tasks(:secret_task)
    assert_equal other, task.project
    # Give the task something to push — otherwise commit_breakdown short-circuits
    # on "No breakdown to push" whether or not the permission check ran, and the
    # test would pass for the wrong reason. With a real breakdown present, an
    # incorrectly-allowed request reaches JiraWriter and attempts a real Jira
    # API call, which WebMock (required above) turns into a loud test failure —
    # the same tell the other two sites' tests rely on.
    task.task_drafts.create!(content: '{"needs_breakdown":false,"total_points":3}', source: TaskDraft::BREAKDOWN_SOURCE)

    post jira_task_breakdown_update_jira_path(task)

    assert_response :redirect
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test "Configuration opens for an Administrator" do
    with_permissions("Administrator")

    get workshop_configuration_path(tab: "integrations")

    assert_response :success
  end

  test "a Product Owner reaches Briefing but not Integrations" do
    with_permissions("Product Owner")

    get workshop_configuration_path(tab: "briefing")
    assert_response :success

    get workshop_configuration_path(tab: "integrations")
    assert_redirected_to workshop_configuration_path(tab: "briefing")
  end

  test "a Project Manager cannot open the configuration page at all" do
    with_permissions("Project Manager")

    get workshop_configuration_path(tab: "briefing")

    assert_response :redirect
  end

  # Until this task, the Configuration controller gated on the retired role
  # predicate while workshop_landing_path already sent Configuration-only
  # people here — so this leg of the landing chain bounced. It is the last
  # unproven branch of the redirect-loop fix.
  test "the landing chain's Configuration leg actually lands" do
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false).merge(configuration: true))

    get workshop_pipeline_path
    follow_redirect!

    assert_response :success
  end

  # Neither product: no HR access, and a membership that grants nothing is not
  # Workshop access either. root sent them to Time & HR, require_employee! sent
  # them back to root, and the browser gave up with too many redirects. Follow
  # the chain wherever it goes rather than counting hops — the point is that it
  # ends on a page, not that it ends in one step.
  test "someone with no product at all lands on a page instead of looping" do
    workspace_memberships(:two_employee).update!(time_hr_access: false)
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false))

    get root_path
    5.times { break unless response.redirect?; follow_redirect! }

    assert_response :success, "the landing path must be a page this person can open"
  end

  # The Setup shortcut on Create Tasks opens Configuration's Create Tasks tab, which is
  # governed by :briefing_config — the one tab a Product Owner holds. Gating
  # the link on :configuration hid it from exactly the people whose tab it is,
  # while the tab itself opened fine if they typed the url.
  test "the Setup shortcut follows the tab it opens, not Configuration" do
    with_permissions("Product Owner")
    assert @membership.reload.briefing_config, "arrangement: a Product Owner holds Briefing Configuration"
    assert_not @membership.configuration, "arrangement: and does not hold Configuration"

    get workshop_pipeline_path

    assert_response :success
    assert_select "a[href=?]", workshop_configuration_path(tab: "briefing"), 1
  end

  test "someone without Briefing Configuration does not get the shortcut" do
    with_permissions("Project Manager")

    get workshop_pipeline_path

    assert_response :success
    assert_select "a[href=?]", workshop_configuration_path(tab: "briefing"), 0
  end

  # A person promoted through the HR directory carries workspace_admin without
  # ever having had an admin ROLE. Everything that used to ask the role has to
  # answer for them too — available_projects is the one that bit us.
  test "an administrator by flag alone sees every project" do
    workspace_memberships(:two_employee).update!(workspace_admin: true)
    ProjectMembership.where(user: @user).destroy_all

    get new_time_entry_path

    assert_response :success
    assert_select "select#time_entry_project_id option", minimum: 2
  end
end
