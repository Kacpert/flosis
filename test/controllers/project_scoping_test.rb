require "test_helper"

# What the deleted client-role tests were really protecting: a restricted
# person must not reach a project they were never added to. The rule now comes
# from the membership rather than from a hard-coded redirect, so it is worth
# asserting directly.
class ProjectScopingTest < ActionDispatch::IntegrationTest
  test "a member sees only the projects they are on" do
    sign_in_as(users(:client_user))
    get jira_tasks_path

    assert_response :success
    assert_match projects(:jira_project).name, response.body
    assert_no_match projects(:other_jira_project).name, response.body
  end

  test "a workspace admin sees every project" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))
    get jira_tasks_path

    assert_response :success
    assert_match projects(:other_jira_project).name, response.body
  end
end
