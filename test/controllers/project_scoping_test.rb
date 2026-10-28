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

  # The listing above only proves a name is absent from a page. These three
  # prove the record itself is out of reach: every one of them resolves its
  # task through `Task.where(project_id: visible_jira_projects.select(:id))`,
  # and swapping that for a bare `Task.find` must not stay green.
  test "a task in a project you are not on cannot be opened" do
    sign_in_as(users(:client_user))

    get jira_task_path(tasks(:secret_task))

    assert_redirected_to jira_tasks_path
    assert_equal "You don't have access to that.", flash[:alert]
  end

  test "a task in a project you are not on has no breakdown page" do
    sign_in_as(users(:client_user))

    get jira_task_breakdown_path(tasks(:secret_task))

    assert_redirected_to jira_tasks_path
    assert_equal "You don't have access to that.", flash[:alert]
  end

  # A JSON caller gets a readable status instead of a redirect to an HTML-only
  # page, so this one asserts the status and that the refusal carries no part
  # of the hidden task with it.
  test "the drafts of a task in a project you are not on are not served" do
    sign_in_as(users(:client_user))

    get jira_task_task_drafts_path(tasks(:secret_task)), as: :json

    assert_response :not_found
    assert_no_match(/#{tasks(:secret_task).name}/, response.body)
  end
end
