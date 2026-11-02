require "test_helper"

class BreakdownChatSessionsControllerTest < ActionDispatch::IntegrationTest
  include FakeChatCliTestHelper

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
  # Integrations "Figma" toggle, which is the PROJECT's. Same predicate
  # ProjectMcpConfig writes the server on, so the prompt cannot name a tool the
  # run was not given.
  def figma_prompt
    controller = BreakdownChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end
    controller.send(:build_initial_prompt)
  end

  test "build_initial_prompt includes the Figma instructions when the project reads Figma" do
    @task.project.update!(figma_read_enabled: true, figma_token: "fig-key")

    assert_includes figma_prompt, "Figma links."
  end

  test "build_initial_prompt omits the Figma instructions when the project does not read Figma" do
    @task.project.update!(figma_read_enabled: false)

    prompt = figma_prompt

    refute_includes prompt, "Figma links."
    refute_includes prompt, "mcp__figma__get_figma_data"
  end

  test "build_initial_prompt ignores the workspace's own Figma column" do
    @task.project.update!(figma_read_enabled: true)
    @task.project.update!(figma_read_enabled: false, figma_token: "fig-key")

    refute_includes figma_prompt, "mcp__figma__get_figma_data"
  end

  test "build_initial_prompt omits the Figma instructions when no token resolves" do
    @task.project.update!(figma_read_enabled: true, figma_token: nil)
    original = FigmaClient.method(:cli_token)
    FigmaClient.define_singleton_method(:cli_token) { nil }

    refute_includes figma_prompt, "mcp__figma__get_figma_data"
  ensure
    FigmaClient.define_singleton_method(:cli_token, original)
  end

  test "a task of a Workshop project without Jira is found" do
    task = flosis_task("Local idea")
    with_fake_cli { post jira_task_breakdown_chat_session_path(task) }
    # Ruling (Plan 4 Task 1): a task out of reach redirects an HTML request,
    # so "not 404" would pass without it; a found task starts streaming.
    assert_response :success
  end

  test "the prompt names the task's own project, not Elvium" do
    task = flosis_task
    checkout!(task.project)
    controller = chat_controller(BreakdownChatSessionsController, task)
    prompt = controller.send(:build_initial_prompt)
    assert_includes prompt, "Flosis — Time tracking and Workshop"
    assert_not_includes prompt, "Elvium"
  end

  test "without a checkout the prompt says there is no code to read" do
    controller = chat_controller(BreakdownChatSessionsController, flosis_task)
    prompt = controller.send(:build_initial_prompt)
    assert_includes prompt, "You have no access to this project's code; reason from the brief and ask."
    assert_not_includes prompt, "Investigate the code FIRST"
  end
end
