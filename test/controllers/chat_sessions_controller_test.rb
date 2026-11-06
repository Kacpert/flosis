require "test_helper"

class ChatSessionsControllerTest < ActionDispatch::IntegrationTest
  include FakeChatCliTestHelper

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
  # Integrations "Figma" toggle, which is the PROJECT's. The gate is the same
  # predicate ProjectMcpConfig writes the server on, so the prompt can never
  # name a tool the run was not given.
  def figma_prompt
    controller = ChatSessionsController.new
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

  # The production shape when the toggle moved to the project: the workspace
  # column still said yes, so the prompt told the model to call a Figma server
  # no project had, and the model improvised.
  test "build_initial_prompt ignores the workspace's own Figma column" do
    @task.project.update!(figma_read_enabled: true)
    @task.project.update!(figma_read_enabled: false, figma_token: "fig-key")

    refute_includes figma_prompt, "mcp__figma__get_figma_data"
  end

  # A toggle with no token anywhere gets no Figma server either, so the prompt
  # must not promise one.
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
    with_fake_cli { post jira_task_chat_session_path(task) }
    # Ruling (Plan 4 Task 1): a task out of reach redirects an HTML request,
    # so "not 404" would pass without it; a found task starts streaming.
    assert_response :success
  end

  test "the prompt names the task's own project, not Elvium" do
    task = flosis_task
    checkout!(task.project)
    controller = chat_controller(ChatSessionsController, task)
    prompt = controller.send(:build_initial_prompt)
    assert_includes prompt, "Flosis — Time tracking and Workshop"
    assert_not_includes prompt, "Elvium"
  end

  test "Claude runs in the project's own checkout" do
    task = tasks(:jira_task)
    task.chat_sessions.destroy_all # an active session is returned as it is, with no new run
    path = checkout!(task.project)
    with_fake_cli do |captured|
      post jira_task_chat_session_path(task)
      assert_equal path, captured[:codebase_path]
    end
  end

  test "a project with no checkout gets an empty folder, no code tools, and a prompt that says so" do
    task = flosis_task
    with_fake_cli do |captured|
      post jira_task_chat_session_path(task)
      assert_equal ChatStreaming::NO_CODEBASE_DIR.to_s, captured[:codebase_path]
      assert_empty Dir.children(ChatStreaming::NO_CODEBASE_DIR)
      assert_equal ClaudeCliService::ALLOWED_TOOLS - %w[Read Glob Grep], captured[:allowed_tools]
    end
    controller = chat_controller(ChatSessionsController, task)
    prompt = controller.send(:build_initial_prompt)
    assert_includes prompt, "You have no access to this project's code; reason from the brief and ask."
    assert_not_includes prompt, "investigation of the"
  end

  # Create Tasks → Setup can switch the Briefing step off, which makes Details
  # Gathering the first AI step. A pipeline task with no brief then gets the
  # personas and feature list the briefing chat would have read, and is not
  # told that a briefing already settled the why.
  def details_prompt
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end
    controller.send(:build_initial_prompt)
  end

  test "a pipeline task with no brief gets the personas and feature list, and no claim the briefing is done" do
    @task.project.update!(briefing_personas: "Recruiters posting jobs.", features_summary: "Users can post jobs.")
    @task.update!(in_pipeline: true, workshop_stage: "details")

    prompt = details_prompt

    assert_includes prompt, "Who uses this app & our perspective"
    assert_includes prompt, "Recruiters posting jobs."
    assert_includes prompt, "What the app already does"
    assert_includes prompt, "Users can post jobs."
    refute_includes prompt, "The briefing stage is ALREADY DONE"
    assert_includes prompt, "There was no briefing step for this ticket"
  end

  test "a pipeline task with a brief keeps the briefed framing" do
    @task.project.update!(briefing_personas: "Recruiters posting jobs.", features_summary: "Users can post jobs.")
    @task.update!(in_pipeline: true, workshop_stage: "details")
    @task.briefs.create!(workspace: workspaces(:one), version: 1, content: "The brief.", status: "briefed").make_current!

    prompt = details_prompt

    assert_includes prompt, "The briefing stage is ALREADY DONE"
    refute_includes prompt, "Who uses this app & our perspective"
  end

  test "a Jira Tasks board ticket outside the pipeline keeps its prompt" do
    @task.project.update!(briefing_personas: "Recruiters posting jobs.", features_summary: "Users can post jobs.")
    @task.update!(in_pipeline: false)

    prompt = details_prompt

    assert_includes prompt, "The briefing stage is ALREADY DONE"
    refute_includes prompt, "Who uses this app & our perspective"
  end

  # A task started from another task's chat (Create Tasks → New task): its
  # first chat has the AI read that conversation and hand over what it said
  # about this task, then reads the handoff, and opens by saying what it got.
  def spun_off_task(handoff: nil)
    source = flosis_task("Add token calculations")
    conversation = ChatSession.create!(task: source, workspace: source.project.workspace, user: users(:one),
                                       purpose: "refine", claude_session_id: "old-session", codebase_path: "/tmp")
    conversation.chat_messages.create!(role: "user", user: users(:one), content: "Billed monthly, prorated on joining.")
    source.project.tasks.create!(name: "Billing", spun_off_from: source, handoff_chat_session: conversation,
                                 handoff: handoff)
  end

  test "a task started from another task's chat hands over first, then its chat reads the handoff" do
    task = spun_off_task

    with_scripted_cli("<handoff>- Billed monthly, prorated on joining</handoff>",
                      "From «Add token calculations» I brought over: monthly billing.") do |runs|
      post jira_task_chat_session_path(task)

      handing_over, chat = runs.sort_by { |run| run[:turn] }
      assert_includes handing_over[:prompt], "**Kacper:** Billed monthly, prorated on joining."
      assert_includes chat[:prompt], "- Billed monthly, prorated on joining"
    end

    assert_response :success
    assert_equal "- Billed monthly, prorated on joining", task.reload.handoff
    assert_includes response.body, "Bringing over what «Add token calculations» said about this task"
    opened = ChatSession.find_active_for(task, purpose: "refine")
    assert_equal "From «Add token calculations» I brought over: monthly billing.", opened.chat_messages.sole.content
  end

  test "a handoff already written is not written again" do
    task = spun_off_task(handoff: "- Billed monthly")

    with_scripted_cli("The chat's first message.") do |runs|
      post jira_task_chat_session_path(task)

      assert_equal 1, runs.size
      assert_includes runs.first[:prompt], "- Billed monthly"
    end
    assert_not_includes response.body, "Bringing over"
  end

  test "the prompt carries the handoff and opens with what was handed over" do
    task = spun_off_task(handoff: "- Billed monthly, prorated on joining")

    prompt = chat_controller(ChatSessionsController, task).send(:build_initial_prompt)

    assert_includes prompt, "# Carried over from «Add token calculations»"
    assert_includes prompt, "- Billed monthly, prorated on joining"
    assert_includes prompt, "Where the description says otherwise, the description wins."
    assert_includes prompt, "From «Add token calculations» I brought over:"
  end

  test "a handoff with nothing in it is said in one line" do
    task = spun_off_task(handoff: "")

    prompt = chat_controller(ChatSessionsController, task).send(:build_initial_prompt)

    assert_includes prompt, "Nothing in that conversation concerned this task."
    assert_includes prompt, "say in one line that nothing from «Add token calculations» concerned this task"
    assert_not_includes prompt, "I brought over:"
  end

  test "a task not started from a chat has no handoff in its prompt" do
    prompt = chat_controller(ChatSessionsController, flosis_task).send(:build_initial_prompt)

    assert_not_includes prompt, "Carried over from"
    assert_not_includes prompt, "brought over"
  end
end
