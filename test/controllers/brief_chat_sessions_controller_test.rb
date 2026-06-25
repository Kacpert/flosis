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

  test "non-admin is blocked" do
    sign_in_as(users(:two)) # employee
    get jira_task_brief_chat_session_path(@task), as: :json
    assert_redirected_to root_path
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
end
