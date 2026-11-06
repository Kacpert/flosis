require "test_helper"

# A task soft-removed because its Jira issue was deleted disappears from the
# lists people pick tasks from, while time already logged to it stays.
class JiraDeletedTasksHiddenTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    @removed = tasks(:jira_task)
    @removed.update!(deleted_at: 1.day.ago)
    sign_in_as(users(:one))
  end

  test "the task picker for logging time leaves it out" do
    get project_tasks_list_path(@project)

    assert_response :success
    assert_no_match(/#{Regexp.escape(@removed.name)}/, response.body)
    assert_match(/#{Regexp.escape(tasks(:local_task).name)}/, response.body)
  end

  test "Bug Reporting leaves it out of the open bugs" do
    @removed.update!(issue_type: "Bug", jira_created_at: Time.current)
    workspaces(:one).update!(workshop_enabled: true)
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }

    get workshop_bugs_path

    assert_response :success
    assert_select "span.clar-mono", text: "ELV-1", count: 0
  end

  test "editing time logged to it keeps the task selected" do
    entry = TimeEntry.create!(user: users(:one), project: @project, workspace: workspaces(:one), task: @removed,
                              started_at: 2.hours.ago, stopped_at: 1.hour.ago)

    get edit_time_entry_path(entry)

    assert_response :success
    assert_select "select[name='time_entry[task_id]'] option[selected][value='#{@removed.id}']"
  end
end
