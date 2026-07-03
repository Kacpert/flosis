require "test_helper"

class Workshop::JiraBrowserControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    @task = tasks(:jira_task) # ELV-1, jira_synced, project jira_project, jira_status_name "In Progress"
  end

  test "renders board tabs for every synced board plus a synthetic Backlog tab" do
    get workshop_jira_browser_path

    assert_response :success
    assert_select ".clar-tab", /Design/
    assert_select ".clar-tab", /DEV board/
    assert_select ".clar-tab", /Backlog/
  end

  test "kanban board shows the task in its mapped column" do
    get workshop_jira_browser_path

    assert_response :success
    # ELV-1 is jira_status_name "In Progress", which maps to the design
    # board's "IN PROGRESS (DESIGN)" column via jira_board_column_statuses.
    assert_select ".clar-key-faint", "ELV-1"
  end

  test "backlog tab renders a table of tasks with no sprint" do
    @task.update!(sprint_id: nil)

    get workshop_jira_browser_path(board: "backlog")

    assert_response :success
    assert_select "table"
    assert_select ".clar-key", "ELV-1"
  end

  test "backlog table is empty when no tasks lack a sprint" do
    get workshop_jira_browser_path(board: "backlog")

    assert_response :success
    assert_select "table"
    assert_select "body", /No tickets match\./
  end

  test "tasks already in the pipeline are excluded from the browser" do
    @task.enter_pipeline!(author: users(:one), stage: "briefing")

    get workshop_jira_browser_path

    assert_response :success
    assert_select ".clar-key-faint", count: 0
  end

  test "POST import pulls an existing Jira task into the pipeline and redirects" do
    assert_no_difference -> { Task.count } do
      post workshop_ideas_path, params: { task_id: @task.id }
    end

    @task.reload
    assert @task.in_pipeline?
    assert_equal "briefing", @task.workshop_stage
    assert_equal users(:one), @task.pipeline_author

    assert_redirected_to workshop_idea_path(@task)
    assert_equal "Imported ELV-1 from Jira", flash[:clar_toast]
  end

  test "POST import seeds a current v0 user brief from the task description" do
    post workshop_ideas_path, params: { task_id: @task.id }

    @task.reload
    brief = @task.briefs.find_by(version: 0)
    assert_not_nil brief
    assert brief.current?
    assert_equal "user", brief.origin
    assert_equal "draft", brief.status
    assert_equal @task.description, brief.content
  end
end
