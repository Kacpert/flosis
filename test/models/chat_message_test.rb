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

  # A question and its answer can land in the same instant, and created_at alone
  # then leaves the transcript's order to the engine — whatever the rows happen
  # to come back as. Touching the middle message moves its row, which is enough
  # to shuffle an untied ORDER BY on either engine.
  test "ordered breaks a created_at tie on id so a transcript keeps its sequence" do
    session = chat_sessions(:one)
    session.chat_messages.destroy_all
    instant = Time.current
    first, second, third = %w[user assistant user].map.with_index do |role, i|
      session.chat_messages.create!(role: role, content: "message #{i}",
                                    created_at: instant, updated_at: instant)
    end
    second.update_columns(content: "message 1 (edited)")

    assert_equal [first, second, third], session.chat_messages.ordered.to_a
  end
end
