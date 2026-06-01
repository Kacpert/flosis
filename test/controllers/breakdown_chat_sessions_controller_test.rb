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
end
