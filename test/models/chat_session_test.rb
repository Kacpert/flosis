require "test_helper"

class ChatSessionTest < ActiveSupport::TestCase
  test "belongs to task" do
    session = chat_sessions(:one)
    assert_equal tasks(:jira_task), session.task
  end

  test "belongs to workspace" do
    session = chat_sessions(:one)
    assert_equal workspaces(:one), session.workspace
  end

  test "belongs to user" do
    session = chat_sessions(:one)
    assert_equal users(:one), session.user
  end

  test "has many chat messages" do
    session = chat_sessions(:one)
    assert_respond_to session, :chat_messages
  end

  test "validates presence of claude_session_id" do
    session = ChatSession.new(task: tasks(:jira_task), workspace: workspaces(:one), user: users(:one), status: "active")
    assert_not session.valid?
    assert_includes session.errors[:claude_session_id], "can't be blank"
  end

  test "validates presence of codebase_path" do
    session = ChatSession.new(task: tasks(:jira_task), workspace: workspaces(:one), user: users(:one), claude_session_id: "abc", status: "active")
    assert_not session.valid?
    assert_includes session.errors[:codebase_path], "can't be blank"
  end

  test "active scope returns only active sessions" do
    assert_includes ChatSession.active, chat_sessions(:one)
  end

  test "find_active_for returns active session for task and user" do
    session = ChatSession.find_active_for(tasks(:jira_task), users(:one))
    assert_equal chat_sessions(:one), session
  end
end
