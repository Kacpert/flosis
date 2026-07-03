require "test_helper"

class Workshop::IdeasControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
  end

  test "posting a title creates a local pipeline task at briefing and redirects to the idea" do
    assert_difference -> { Task.count }, 1 do
      post workshop_ideas_path, params: { idea: { title: "Aggregated CSV export", description: "" } }
    end

    task = Task.order(:id).last
    assert_equal "Aggregated CSV export", task.name
    assert_equal tasks(:jira_task).project_id, task.project_id
    assert task.in_pipeline?
    assert_equal "briefing", task.workshop_stage
    assert_not_nil task.pipeline_entered_at
    assert_equal users(:one), task.pipeline_author

    assert_redirected_to workshop_idea_path(task)
  end

  test "description present seeds a current v0 user draft brief" do
    post workshop_ideas_path, params: { idea: { title: "Idea with description", description: "A sentence or two." } }

    task = Task.order(:id).last
    brief = task.briefs.find_by(version: 0)
    assert_not_nil brief
    assert brief.current?
    assert_equal "user", brief.origin
    assert_equal "draft", brief.status
    assert_equal "A sentence or two.", brief.content
  end

  test "no description means no brief is seeded" do
    post workshop_ideas_path, params: { idea: { title: "Idea without description", description: "" } }

    task = Task.order(:id).last
    assert_equal 0, task.briefs.count
  end

  test "blank title is unprocessable, not a server error" do
    assert_no_difference -> { Task.count } do
      post workshop_ideas_path, params: { idea: { title: "", description: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "duplicate title in the same project is unprocessable, not a server error" do
    existing = tasks(:jira_task)

    assert_no_difference -> { Task.count } do
      post workshop_ideas_path, params: { idea: { title: existing.name, description: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "importing a task from another project is rejected (not scoped to the workshop project)" do
    # secret_task lives in other_jira_project, outside current_workshop_project's
    # scope, so import must not reach it — the lookup 404s rather than leaking it
    # into this project's pipeline.
    other = tasks(:secret_task)

    # In integration tests the RecordNotFound is caught by the exception
    # middleware and rendered as a 404 rather than propagating to the test.
    post workshop_ideas_path, params: { task_id: other.id }
    assert_response :not_found
    refute other.reload.in_pipeline, "cross-project task must not enter the pipeline"
  end
end
