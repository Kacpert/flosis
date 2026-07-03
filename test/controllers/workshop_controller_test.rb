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
    # index now redirects to the Create Tasks pipeline (Task 2.3).
    get workshop_path
    assert_redirected_to workshop_pipeline_path
    get new_idea_workshop_path(project_id: @project.id)
    assert_response :success
    assert_match "WS-1 Design task", response.body
  end

  test "new_idea has a mode toggle and a task search" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get new_idea_workshop_path(project_id: @project.id)
    assert_response :success
    assert_select "[data-controller=?]", "idea-picker"
    assert_select "[data-idea-picker-target=existingTab]"
    assert_select "[data-idea-picker-target=newTab]"
    assert_select "input[data-idea-picker-target=search]"
    assert_select "[data-idea-picker-target=item]", { count: 1 } # the one design task
  end

  # NOTE: "in-progress ideas to resume" and "landing choice cards" were features
  # of the old (pre-Task 2.3) `workshop#index` landing, which no longer renders
  # (it redirects to the Create Tasks pipeline — see Workshop::PipelineController).
  # The pipeline shows all in-pipeline ideas (any stage) as rows — see
  # test/controllers/workshop/pipeline_controller_test.rb — so a task already in
  # the pipeline is always visible there, and the two entry cards (New idea /
  # Existing Jira task) are covered by TwoProductUxSmokeTest's
  # "workshop landing offers New idea / Existing Jira task entry points".

  test "new_idea honors the mode param so the chosen panel opens" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get new_idea_workshop_path(project_id: @project.id, mode: "new")
    assert_select "[data-idea-picker-mode-value=new]"
    get new_idea_workshop_path(project_id: @project.id, mode: "existing")
    assert_select "[data-idea-picker-mode-value=existing]"
  end

  test "employee is blocked even when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:two)) # non-admin, no workshop access
    get workshop_path
    # require_product!(:workshop) fires first → bounced to their Time & HR landing.
    assert_redirected_to time_entries_path
  end

  test "employee with workshop access but not admin is blocked from the tab" do
    @workspace.update!(workshop_enabled: true)
    users(:two).membership_for(@workspace).update!(workshop_access: true)
    sign_in_as(users(:two))
    get workshop_path
    # passes the product gate, but the Workshop tab is admin-only.
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

  test "sidebar shows Workshop for admin when enabled and in the Workshop product" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    # The sidebar's "Create Tasks" item is the Workshop tab now that the
    # pipeline route is real (Task 2.3) — it points at workshop_pipeline_path,
    # not the old bare workshop_path.
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_pipeline_path
  end

  test "sidebar hides Workshop when disabled" do
    @workspace.update!(workshop_enabled: false)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    get jira_tasks_path
    assert_select "a[href=?]", workshop_pipeline_path, count: 0
  end

  test "Workshop nav is absent in the Time & HR product" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get time_entries_path
    assert_select "a[href=?]", workshop_pipeline_path, count: 0
  end
end
