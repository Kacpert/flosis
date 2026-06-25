require "test_helper"

class WorkshopControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @project = @workspace.projects.create!(name: "WS", color: "#444444",
      external_type: "jira", external_reference: "WS")
    @design = @project.tasks.create!(name: "WS-1 Design task", external_type: "jira",
      external_reference: "WS-1", sprint_name: "Design Sprint 4")
  end

  test "workshop hidden when toggle off" do
    @workspace.update!(workshop_enabled: false)
    sign_in_as(users(:one))
    get workshop_path
    assert_redirected_to root_path
  end

  test "admin sees workshop and the design-sprint task when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get workshop_path
    assert_response :success
    get new_idea_workshop_path(project_id: @project.id)
    assert_response :success
    assert_match "WS-1 Design task", response.body
  end

  test "employee is blocked even when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:two)) # non-admin
    get workshop_path
    assert_redirected_to root_path
  end

  test "start with a new idea creates a local task and redirects to brief" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    assert_difference -> { @project.tasks.count }, 1 do
      post start_workshop_path, params: { project_id: @project.id, mode: "new",
        title: "Fresh idea", body: "do a thing" }
    end
    task = @project.tasks.order(:created_at).last
    assert_nil task.external_reference
    assert_redirected_to workshop_brief_path(task)
  end

  test "start with an existing task redirects to its brief" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    post start_workshop_path, params: { project_id: @project.id, mode: "existing", task_id: @design.id }
    assert_redirected_to workshop_brief_path(@design)
  end

  test "brief page renders for a task" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    Brief.create!(task: @design, workspace: @workspace, version: 1, content: "the concept")
    get workshop_brief_path(@design)
    assert_response :success
    assert_match "the concept", response.body
  end

  test "sidebar shows Workshop for admin when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", workshop_path
  end

  test "sidebar hides Workshop when disabled" do
    @workspace.update!(workshop_enabled: false)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", workshop_path, count: 0
  end
end
