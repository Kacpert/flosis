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

  test "fixture session defaults to refine purpose" do
    assert_equal "refine", chat_sessions(:one).purpose
  end

  test "find_active_for is scoped by purpose" do
    # The refine session exists; a breakdown lookup should not return it.
    assert_nil ChatSession.find_active_for(tasks(:jira_task), users(:one), purpose: "breakdown")

    breakdown = ChatSession.create!(
      task: tasks(:jira_task), workspace: workspaces(:one), user: users(:one),
      claude_session_id: "bd-uuid", codebase_path: "/tmp", purpose: "breakdown"
    )
    assert_equal breakdown, ChatSession.find_active_for(tasks(:jira_task), users(:one), purpose: "breakdown")
    # And the refine lookup still returns the refine session, not the breakdown one.
    assert_equal chat_sessions(:one), ChatSession.find_active_for(tasks(:jira_task), users(:one), purpose: "refine")
  end

  test "validates purpose inclusion" do
    session = ChatSession.new(task: tasks(:jira_task), workspace: workspaces(:one), user: users(:one),
                              claude_session_id: "abc", codebase_path: "/tmp", purpose: "bogus")
    assert_not session.valid?
    assert_includes session.errors[:purpose], "is not included in the list"
  end
end
