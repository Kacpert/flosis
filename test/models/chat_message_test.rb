require "test_helper"

class ChatMessageTest < ActiveSupport::TestCase
  test "belongs to chat session" do
    message = chat_messages(:greeting)
    assert_equal chat_sessions(:one), message.chat_session
  end

  test "validates presence of role" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), content: "hello")
    assert_not message.valid?
    assert_includes message.errors[:role], "can't be blank"
  end

  test "validates role inclusion" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), content: "hello", role: "invalid")
    assert_not message.valid?
    assert_includes message.errors[:role], "is not included in the list"
  end

  test "validates presence of content" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), role: "user")
    assert_not message.valid?
    assert_includes message.errors[:content], "can't be blank"
  end

  test "ordered scope returns messages in chronological order" do
    assert_equal chat_messages(:greeting), chat_sessions(:one).chat_messages.ordered.first
  end
end
