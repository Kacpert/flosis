require "test_helper"

class BreakdownChatSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @task = tasks(:jira_task)
  end

  test "show returns 404 when no active breakdown session" do
    # The fixture session is a refine session; breakdown chat must not see it.
    get jira_task_breakdown_chat_session_path(@task), as: :json
    assert_response :not_found
  end

  test "show returns the breakdown session when one exists" do
    session = ChatSession.create!(
      task: @task, workspace: workspaces(:one), user: users(:one),
      claude_session_id: "bd-uuid", codebase_path: "/tmp", purpose: "breakdown"
    )
    session.chat_messages.create!(role: "assistant", content: "hi")

    get jira_task_breakdown_chat_session_path(@task), as: :json
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal session.id, json["chat_session"]["id"]
    assert_equal "breakdown", json["chat_session"]["purpose"]
  end

  test "destroy only closes breakdown sessions, leaving refine session active" do
    breakdown = ChatSession.create!(
      task: @task, workspace: workspaces(:one), user: users(:one),
      claude_session_id: "bd-uuid", codebase_path: "/tmp", purpose: "breakdown"
    )

    delete jira_task_breakdown_chat_session_path(@task)
    assert_response :no_content

    assert_equal "closed", breakdown.reload.status
    assert_equal "active", chat_sessions(:one).reload.status, "refine session must stay active"
  end

  test "message requires an active session" do
    post message_jira_task_breakdown_chat_session_path(@task), params: { content: "hi" }, as: :json
    assert_response :not_found
  end

  test "requires authentication" do
    sign_out
    get jira_task_breakdown_chat_session_path(@task), as: :json
    assert_response :redirect
  end

  # Task 9.2: the Figma instruction paragraph is gated by the Configuration ->
  # Integrations "Figma" toggle (workspace.figma_read_enabled). Enabled
  # preserves today's behavior; disabled must not instruct the AI to read Figma.
  test "build_initial_prompt includes the Figma instructions when figma_read_enabled is true" do
    @task.project.workspace.update!(figma_read_enabled: true)
    controller = BreakdownChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    assert_includes prompt, "Figma links."
  end

  test "build_initial_prompt omits the Figma instructions when figma_read_enabled is false" do
    @task.project.workspace.update!(figma_read_enabled: false)
    controller = BreakdownChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "Figma links."
    refute_includes prompt, "mcp__figma__get_figma_data"
  end
end
