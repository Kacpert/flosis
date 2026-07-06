require "test_helper"

class BriefChatSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @task = tasks(:jira_task)
    sign_in_as(users(:one)) # admin
  end

  test "show returns 404 when no active brief session" do
    get jira_task_brief_chat_session_path(@task), as: :json
    assert_response :not_found
  end

  test "show returns the brief session when one exists" do
    session = ChatSession.create!(
      task: @task, workspace: @workspace, user: users(:one),
      claude_session_id: "br-uuid", codebase_path: "/tmp", purpose: "brief"
    )
    session.chat_messages.create!(role: "assistant", content: "hi")

    get jira_task_brief_chat_session_path(@task), as: :json
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal session.id, json["chat_session"]["id"]
    assert_equal "brief", json["chat_session"]["purpose"]
  end

  test "destroy only closes brief sessions, leaving the refine session active" do
    brief = ChatSession.create!(
      task: @task, workspace: @workspace, user: users(:one),
      claude_session_id: "br-uuid", codebase_path: "/tmp", purpose: "brief"
    )
    delete jira_task_brief_chat_session_path(@task)
    assert_response :no_content
    assert_equal "closed", brief.reload.status
    assert_equal "active", chat_sessions(:one).reload.status, "refine session must stay active"
  end

  test "destroy soft-closes the session but keeps the task's Brief rows" do
    session = ChatSession.create!(
      task: @task, workspace: @workspace, user: users(:one),
      claude_session_id: "br-uuid", codebase_path: "/tmp", purpose: "brief"
    )
    brief = @task.briefs.create!(
      workspace: @workspace, chat_session: session, version: 1,
      content: "The concept is X.", status: "draft"
    )

    assert_difference -> { Brief.count }, 0 do
      delete jira_task_brief_chat_session_path(@task)
    end

    assert_response :no_content
    assert_equal "closed", session.reload.status, "session must be soft-closed, not destroyed"
    assert Brief.exists?(brief.id), "Brief rows belong to the task, not the session, and must survive a session reset"
  end

  test "non-admin without workshop access is blocked" do
    sign_in_as(users(:two)) # employee without Workshop access
    get jira_task_brief_chat_session_path(@task), as: :json
    # require_product!(:workshop) bounces them to their Time & HR landing.
    assert_redirected_to time_entries_path
  end

  # require_workshop_member! (replacing require_admin!) must still block
  # clients explicitly — can_access_workshop? returns true for clients, and
  # /jira_tasks/* is client-allowed by redirect_clients_to_jira, so this guard
  # is the only thing stopping a client from spawning an AI brief session.
  test "client is blocked from show even though can_access_workshop? is true for clients" do
    sign_in_as(users(:client_user))
    get jira_task_brief_chat_session_path(@task), as: :json
    assert_redirected_to root_path
  end

  test "client is blocked from posting a message" do
    session = ChatSession.create!(
      task: @task, workspace: @workspace, user: users(:one),
      claude_session_id: "br-uuid", codebase_path: "/tmp", purpose: "brief"
    )
    sign_in_as(users(:client_user))
    post message_jira_task_brief_chat_session_path(@task), params: { content: "hi" }, as: :json
    assert_redirected_to root_path
    assert_equal "active", session.reload.status, "client's blocked request must not touch the session"
  end

  test "admin (owner role, workshop_access true) is allowed through the guard" do
    sign_in_as(users(:one)) # one_owner fixture: role owner, workshop_access true
    get jira_task_brief_chat_session_path(@task), as: :json
    assert_response :not_found # no active session yet — but NOT redirected, proving the guard passed
  end

  test "blocked when workshop disabled" do
    @workspace.update!(workshop_enabled: false)
    get jira_task_brief_chat_session_path(@task), as: :json
    assert_redirected_to root_path
  end

  test "extract_and_save_results creates a versioned Brief per <brief> block" do
    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    controller.instance_variable_set(:@chat_session, nil)
    def controller.current_workspace; Workspace.find_by(name: "Test Workspace"); end

    text = "lead-in <brief>The concept is X. Value: Y.</brief> trailing"
    assert_difference -> { @task.briefs.count }, 1 do
      controller.send(:extract_and_save_results, text)
    end
    b = @task.briefs.newest_first.first
    assert_equal 1, b.version
    assert_match "concept is X", b.content
    assert_equal "draft", b.status
  end

  # Unit-tests build_initial_prompt directly on a bare controller instance —
  # same seam the extract_and_save_results test above already uses (set
  # @task, stub the params/current_workspace accessors this private method
  # touches, then call it via #send). This gives a real assertion on the
  # generated prompt text without needing to spin up the SSE/create endpoint.
  test "build_initial_prompt appends the refine_current paragraph and current brief when mode=refine_current" do
    @task.briefs.create!(
      workspace: @workspace, version: 1, content: "Existing brief content Z.", status: "draft"
    )

    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; { mode: "refine_current" }; end

    prompt = controller.send(:build_initial_prompt)

    assert_includes prompt, "The team already has a current version of the brief (included below). Ask what should change instead of starting from zero."
    assert_includes prompt, "Existing brief content Z."
  end

  test "build_initial_prompt does not append the refine_current paragraph without the mode param" do
    @task.briefs.create!(
      workspace: @workspace, version: 1, content: "Existing brief content Z.", status: "draft"
    )

    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "The team already has a current version of the brief"
    refute_includes prompt, "Existing brief content Z."
  end

  test "build_initial_prompt ignores mode=refine_current when there is no current brief" do
    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; { mode: "refine_current" }; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "The team already has a current version of the brief"
  end

  test "build_initial_prompt frames a UX-minded PO that investigates code but talks product, tersely" do
    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    # Product Owner with UX/UI sensibility.
    assert_includes prompt, "Product Owner with strong UX/UI sensibility"
    # Terse/direct contract — no water.
    assert_includes prompt, "SHORT and DIRECT"
    # It SHOULD investigate the codebase to learn conventions (e.g. required fields).
    assert_includes prompt, "Investigate the codebase"
    assert_includes prompt, "required fields"
    assert_includes prompt, "CLAUDE.md"
    # But still talks product, not an implementation readout.
    assert_includes prompt, "Talk product, not implementation"
    assert_includes prompt, "Don't dump code at the user"
    # Sharp, critical mind — challenges worth/value, not a yes-man.
    assert_includes prompt, "SHARP, CRITICAL mind"
    assert_includes prompt, "not a yes-man"
    assert_includes prompt, "worth building"
    assert_includes prompt, "value do users get"
    # Always carry Loom/video links into the brief.
    assert_includes prompt, "Loom"
    assert_includes prompt, "References:"
  end

  test "briefing chat uses the full read/search tool set (inherits the default)" do
    # nil → ChatStreaming/ClaudeCliService fall back to ALLOWED_TOOLS (incl. Read/Glob/Grep),
    # so the PO can read the codebase to ground its advice.
    assert_nil BriefChatSessionsController.new.send(:chat_allowed_tools)
    assert_includes ClaudeCliService::ALLOWED_TOOLS, "Read"
    assert_includes ClaudeCliService::ALLOWED_TOOLS, "Grep"
  end

  test "build_initial_prompt appends the project's personas and feature summary when present" do
    @task.project.update!(
      briefing_personas: "Recruiters posting jobs; Admins configuring.",
      features_summary: "Users can post jobs, review candidates, and export CSVs."
    )
    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    assert_includes prompt, "Who uses this app & our perspective"
    assert_includes prompt, "Recruiters posting jobs; Admins configuring."
    assert_includes prompt, "What the app already does"
    assert_includes prompt, "Users can post jobs, review candidates, and export CSVs."
  end

  test "build_initial_prompt omits the personas/features sections when blank" do
    @task.project.update!(briefing_personas: nil, features_summary: nil)
    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    def controller.params; {}; end

    prompt = controller.send(:build_initial_prompt)

    refute_includes prompt, "Who uses this app & our perspective"
    refute_includes prompt, "What the app already does"
  end
end
