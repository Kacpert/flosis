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

  # Most messages are plain; Designs marks the ones its screen draws differently.
  test "kind is empty unless a message was given one" do
    session = chat_sessions(:one)
    assert_nil session.chat_messages.create!(role: "user", content: "hello").kind

    %w[summary context missing error system].each do |kind|
      message = session.chat_messages.create!(role: "assistant", content: "x", kind: kind)
      assert_equal kind, message.reload.kind
    end
  end

  # Ruling P2-R10: a kind the screen does not know would be drawn as a plain
  # message, a typo included.
  test "a kind is one Designs knows, or none" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), role: "assistant", content: "x", kind: "sumary")
    assert_not message.valid?
    assert_includes message.errors[:kind], "is not included in the list"
    assert ChatMessage.new(chat_session: chat_sessions(:one), role: "assistant", content: "x", kind: nil).valid?
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

  # Kacper (2026-11-19): a person can add images to a task's AI chat.
  def image(name = "inspiration.png", type = "image/png")
    Rack::Test::UploadedFile.new(file_fixture(name), type)
  end

  test "a person's message can be images alone" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), role: "user", content: "")
    message.images.attach(image)
    assert message.valid?, message.errors.full_messages.to_sentence
  end

  test "only PNG, JPG, GIF or WebP images, at most ten" do
    pdf = ChatMessage.new(chat_session: chat_sessions(:one), role: "user", content: "see")
    pdf.images.attach(io: StringIO.new("%PDF-1.4 not an image"), filename: "spec.pdf", content_type: "application/pdf")
    assert_not pdf.valid?
    assert_includes pdf.errors[:images].to_sentence, "spec.pdf is not a PNG, JPG, GIF or WebP image"

    many = ChatMessage.new(chat_session: chat_sessions(:one), role: "user", content: "see")
    11.times { many.images.attach(image) }
    assert_not many.valid?
    assert_includes many.errors[:images].to_sentence, "at most 10 per message"
  end

end
