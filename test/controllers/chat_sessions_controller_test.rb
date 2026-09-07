require "test_helper"

class ChatSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @task = tasks(:jira_task)
  end

  test "create returns existing active session" do
    session = chat_sessions(:one)
    post jira_task_chat_session_path(@task), as: :json
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal session.id, json["chat_session"]["id"]
    assert json["chat_session"]["messages"].is_a?(Array)
  end

  test "show returns session with messages" do
    get jira_task_chat_session_path(@task), as: :json
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal chat_sessions(:one).id, json["chat_session"]["id"]
    assert json["chat_session"]["messages"].length >= 1
  end

  test "show serializes the persisted thinking so the toggle survives reload" do
    chat_sessions(:one).chat_messages.create!(
      role: "assistant", content: "The clean answer.", thinking: "Let me search the code.\n\nNow the locale."
    )

    get jira_task_chat_session_path(@task), as: :json
    assert_response :success

    msg = JSON.parse(response.body)["chat_session"]["messages"].last
    assert_equal "The clean answer.", msg["content"]
    assert_includes msg["thinking"], "Let me search the code."
  end

  # The conversation belongs to the ticket, not to whoever started it: anyone in
  # the workspace opens the same one. A workspace_client (the client-side
  # Product Owner) used to get a 403 here, so the chat panel rendered empty
  # while the page around it worked — the conversation looked lost.
  test "a workspace_client sees the conversation someone else started" do
    session = chat_sessions(:one)
    session.chat_messages.create!(role: "user", content: "Started by an employee.", user: users(:one))
    sign_in_as(users(:workspace_client_user))

    get jira_task_chat_session_path(@task), as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal session.id, json["chat_session"]["id"]
    assert_includes json["chat_session"]["messages"].map { |m| m["content"] }, "Started by an employee."
  end

  test "a workspace_client may open the chat" do
    sign_in_as(users(:workspace_client_user))

    post jira_task_chat_session_path(@task), as: :json

    assert_response :success
  end

  test "show returns 404 when no active session" do
    chat_sessions(:one).update!(status: "closed")
    get jira_task_chat_session_path(@task), as: :json
    assert_response :not_found
  end

  test "create requires authentication" do
    sign_out
    post jira_task_chat_session_path(@task), as: :json
    assert_response :redirect
  end

  # Unit-tests build_initial_prompt directly on a bare controller instance —
  # same seam BriefChatSessionsControllerTest uses for its refine_current
  # coverage — to get a real assertion on the generated prompt text without
  # spinning up the SSE/create endpoint.
  # The draft block is stripped out of the chat and rendered in the Description
  # panel, so a lead-in like "Here's the refined ticket:" left the reader
  # looking at a sentence with nothing after it — a client had no idea the
  # description had been rewritten at all.
  test "the prompt tells the AI to point the reader at the description panel" do
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    assert_match(/REMOVED from the chat/, prompt)
    assert_match(/Description panel on the right/, prompt)
    assert_match(/version selector/, prompt)
    assert_match(/never write as though the ticket were in the chat/, prompt)
  end

  test "build_initial_prompt appends the refine_current paragraph and current brief when mode=refine_current" do
    workspace = workspaces(:one)
    @task.briefs.create!(
      workspace: workspace, version: 1, content: "Briefed content Q.", status: "draft"
    ).make_current!

    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; { mode: "refine_current" }; end

    prompt = controller.send(:build_initial_prompt)

    assert_includes prompt, "Briefed version is in."
    assert_includes prompt, "Briefed content Q."
  end

  test "build_initial_prompt does not append the refine_current paragraph without the mode param" do
    workspace = workspaces(:one)
    @task.briefs.create!(
      workspace: workspace, version: 1, content: "Briefed content Q.", status: "draft"
    ).make_current!

    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "Briefed version is in."
    refute_includes prompt, "Briefed content Q."
  end

  test "build_initial_prompt ignores mode=refine_current when there is no current brief" do
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; { mode: "refine_current" }; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "Briefed version is in."
  end

  test "details prompt tells the AI to talk product in chat, not dump code / file paths" do
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    # Investigates for grounding but speaks to a non-technical PO.
    assert_includes prompt, "Talk PRODUCT, not implementation"
    assert_includes prompt, "Do NOT dump code at the user"
    assert_includes prompt, "no line numbers"
    # First message is plain-language, not "referencing concrete files".
    assert_includes prompt, "PLAIN-LANGUAGE summary"
    refute_includes prompt, "referencing concrete files"
  end

  # Task 9.2: the Figma instruction paragraph is gated by the Configuration ->
  # Integrations "Figma" toggle (workspace.figma_read_enabled). Enabled
  # preserves today's behavior; disabled must not instruct the AI to read Figma.
  test "build_initial_prompt includes the Figma instructions when figma_read_enabled is true" do
    @task.project.workspace.update!(figma_read_enabled: true)
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    assert_includes prompt, "Figma links."
  end

  test "build_initial_prompt omits the Figma instructions when figma_read_enabled is false" do
    @task.project.workspace.update!(figma_read_enabled: false)
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "Figma links."
    refute_includes prompt, "mcp__figma__get_figma_data"
  end
end
