require "test_helper"

class TaskBreakdownsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @task = tasks(:jira_task)
  end

  test "show renders the breakdown page" do
    get jira_task_breakdown_path(@task)
    assert_response :success
    assert_select "[data-controller='breakdown']"
  end

  test "show requires authentication" do
    sign_out
    get jira_task_breakdown_path(@task)
    assert_response :redirect
  end

  test "index returns only breakdown-source versions, newest first" do
    @task.task_drafts.create!(content: "refined description", source: TaskDraft::REFINE_SOURCE)
    @task.task_drafts.create!(content: { total_points: 3, needs_breakdown: false, subtasks: [] }.to_json,
                              source: TaskDraft::BREAKDOWN_SOURCE)
    @task.task_drafts.create!(content: { total_points: 8, needs_breakdown: true,
                                         subtasks: [{ title: "A", points: 8 }] }.to_json,
                              source: TaskDraft::BREAKDOWN_SOURCE)

    get jira_task_task_breakdowns_path(@task), as: :json
    assert_response :success

    versions = JSON.parse(response.body)["versions"]
    assert_equal 2, versions.length, "refined (ai) draft must be excluded"
    assert_equal 8, versions.first["breakdown"]["total_points"], "newest first"
    assert_equal 3, versions.last["breakdown"]["total_points"]
  end

  test "index skips versions whose content is not valid JSON" do
    @task.task_drafts.create!(content: "not json at all", source: TaskDraft::BREAKDOWN_SOURCE)
    @task.task_drafts.create!(content: { total_points: 5, needs_breakdown: false, subtasks: [] }.to_json,
                              source: TaskDraft::BREAKDOWN_SOURCE)

    get jira_task_task_breakdowns_path(@task), as: :json
    assert_response :success
    versions = JSON.parse(response.body)["versions"]
    assert_equal 1, versions.length
  end
end
