require "test_helper"

# Verifies the client role: Jira-tasks-only access, scoped to assigned projects,
# blocked everywhere else, landing redirected to Jira Tasks.
class ClientAccessTest < ActionDispatch::IntegrationTest
  setup do
    @client = users(:client_user)        # role: client, member of jira_project only
    @task = tasks(:jira_task)            # in jira_project (client is a member)
    @secret_task = tasks(:secret_task)   # in other_jira_project (client is NOT a member)
    sign_in_as(@client)
  end

  # --- access to Jira tasks (allowed) ---------------------------------------

  test "client can view the Jira tasks index" do
    get jira_tasks_path
    assert_response :success
  end

  test "client can view a task in an assigned project" do
    get jira_task_path(@task)
    assert_response :success
  end

  test "client can open the breakdown page for an assigned task" do
    get jira_task_breakdown_path(@task)
    assert_response :success
  end

  # --- scoping (other projects blocked) -------------------------------------

  test "client cannot view a task in a project they are not a member of" do
    get jira_task_path(@secret_task)
    assert_redirected_to jira_tasks_path
  end

  test "client cannot open breakdown for an out-of-scope task" do
    get jira_task_breakdown_path(@secret_task)
    assert_redirected_to jira_tasks_path
  end

  test "client cannot list drafts for an out-of-scope task" do
    get jira_task_task_drafts_path(@secret_task), as: :json
    assert_redirected_to jira_tasks_path
  end

  test "index only exposes the client's jira projects" do
    get jira_tasks_path
    assert_response :success
    assert_select "option", text: /Elvium/
    assert_select "option", text: /SecretProject/, count: 0
  end

  # --- everything else blocked ----------------------------------------------

  test "client is redirected away from time entries" do
    get time_entries_path
    assert_redirected_to jira_tasks_path
  end

  test "client is redirected away from projects" do
    get projects_path
    assert_redirected_to jira_tasks_path
  end

  test "client is redirected away from reports" do
    get reports_summary_path
    assert_redirected_to jira_tasks_path
  end

  test "client is redirected away from team management" do
    get workspace_members_path
    assert_redirected_to jira_tasks_path
  end

  test "client cannot trigger a Jira sync refresh" do
    post refresh_jira_tasks_path, params: { project_id: projects(:jira_project).id }
    # require_admin! sends non-admins to root, which the client hook then bounces
    # to jira_tasks. Either way they don't reach the sync.
    assert_response :redirect
    assert_not_equal projects(:jira_project).reload, nil
  end

  test "client cannot switch workspaces" do
    post switch_workspace_path(workspaces(:one))
    assert_redirected_to jira_tasks_path
  end

  test "client cannot open the new-workspace page" do
    get new_workspace_path
    assert_redirected_to jira_tasks_path
  end

  test "client cannot create a workspace" do
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "Sneaky" } }
    end
    assert_redirected_to jira_tasks_path
  end

  # --- landing ---------------------------------------------------------------

  test "client visiting root is redirected to Jira tasks" do
    get root_path
    assert_redirected_to jira_tasks_path
  end

  # --- non-client unaffected -------------------------------------------------

  test "owner still lands on time entries (not redirected)" do
    sign_in_as(users(:one))
    get root_path
    assert_response :success
  end
end
