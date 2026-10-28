require "test_helper"

# The admin-only GitHub banner is a layout gate: it runs on every page in the
# HR layout. Asking which Workshop project is current must not CHOOSE one —
# viewing a timesheet is not a decision about the Workshop.
class AuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # workspace admin — the only person the banner renders for
  end

  test "an HR page render leaves the session's Workshop project selection untouched" do
    get time_entries_path

    assert_response :success
    assert_nil session[:workshop_project_id]
  end

  test "an HR page render with the banner showing still chooses nothing" do
    @project.update!(github_token: "ghp_token", github_status_ok: false,
                     github_status_error: "401 Unauthorized")

    get time_entries_path

    assert_response :success
    assert_select "body", /PR reviewer can't reach GitHub/
    assert_nil session[:workshop_project_id]
  end

  test "an explicit Workshop choice is still honoured by the banner" do
    post switch_workshop_project_path, params: { project_id: projects(:other_jira_project).id }
    projects(:other_jira_project).update!(github_token: "ghp_token", github_status_ok: false,
                                          github_status_error: "403 Forbidden")
    @project.update!(github_token: "ghp_token", github_status_ok: true)

    get time_entries_path

    assert_select "body", /403 Forbidden/
    assert_equal projects(:other_jira_project).id, session[:workshop_project_id]
  end
end
