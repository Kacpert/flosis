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

  test "GET show renders the workspace shell with the stepper at the idea's stage" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea)

    assert_response :success
    assert_select "h1", idea.name
    assert_select ".clar-key", idea.external_reference
    assert_select "[data-stepper-stage='briefing'][data-stepper-current='true']"
  end

  test "GET show at briefing stage renders the Clar chat panel wired to the brief_chat routes" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "briefing")

    assert_response :success
    assert_select "[data-controller='clar-chat']" do
      assert_select "[data-clar-chat-create-url-value='#{jira_task_brief_chat_session_path(idea)}']"
      assert_select "[data-clar-chat-message-url-value='#{message_jira_task_brief_chat_session_path(idea)}']"
      assert_select "[data-clar-chat-persona-value='briefing']"
      assert_select "[data-clar-chat-target='messages']"
      assert_select "[data-clar-chat-target='input']"
    end
    assert_select "span", text: /Briefing/
    assert_select "span", text: /Reads project & task description first/
    assert_select "button", text: /Reset session/
  end

  test "GET show at details stage does not render the briefing chat panel" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)

    get workshop_idea_path(idea, stage: "details")

    assert_response :success
    assert_select "[data-controller='clar-chat']", count: 0
  end

  test "PATCH update renames a local task and sets a toast" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    patch workshop_idea_path(idea), params: { idea: { name: "New name" } }

    assert_response :success
    assert_equal "New name", idea.reload.name
  end

  test "POST advance with a legal transition sets workshop_stage" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    post advance_workshop_idea_path(idea), params: { to: "details" }

    assert_response :redirect
    assert_equal "details", idea.reload.workshop_stage
  end

  test "POST advance with an illegal transition is rejected" do
    idea = tasks(:jira_task)
    idea.update!(in_pipeline: true, workshop_stage: "new", pipeline_entered_at: 1.hour.ago)

    post advance_workshop_idea_path(idea), params: { to: "ready" }

    assert_response :unprocessable_entity
    assert_equal "new", idea.reload.workshop_stage
  end

  test "POST save_locally stamps brief_saved_locally_at, sets a toast, and keeps the briefing stage" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)

    post save_locally_workshop_idea_path(idea)

    assert_response :redirect
    assert_not_nil idea.reload.brief_saved_locally_at
    assert_equal "briefing", idea.workshop_stage
    assert_equal "Brief saved to the task locally · not pushed", flash[:clar_toast]
  end

  def stub_commit_brief(result)
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| result }
    yield
  ensure
    JiraWriter.define_method(:commit_brief, orig)
  end

  test "POST push_jira on success clears brief_saved_locally_at, advances to details, and sets a toast" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago,
                 brief_saved_locally_at: 1.minute.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft",
                        content: "the brief").make_current!

    stub_commit_brief({ ok: true, key: "ELV-9", url: "https://example.com/ELV-9" }) do
      post push_jira_workshop_idea_path(idea)
    end

    assert_response :redirect
    idea.reload
    assert_nil idea.brief_saved_locally_at
    assert_equal "details", idea.workshop_stage
    assert_equal "Pushed to Jira · AI actions = Briefed", flash[:clar_toast]
  end

  test "POST push_jira on failure does not advance the stage and surfaces the error" do
    idea = tasks(:local_task)
    idea.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
    idea.briefs.create!(workspace: idea.project.workspace, version: 0, origin: "user", status: "draft",
                        content: "the brief").make_current!

    stub_commit_brief({ ok: false, error: "403 Forbidden" }) do
      post push_jira_workshop_idea_path(idea)
    end

    assert_equal "briefing", idea.reload.workshop_stage
    follow_redirect!
    assert_match "403", response.body
  end
end
