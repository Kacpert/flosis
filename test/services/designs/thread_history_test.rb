require "test_helper"

# What a design turn that starts a new Claude session is told of the thread
# before its message (2026-11-27): the person's messages and the replies, as
# the chat shows them.
class Designs::ThreadHistoryTest < ActiveSupport::TestCase
  setup do
    @session = Designs::Threads.new_session(projects(:jira_project), users(:one))
  end

  def said(role, content, kind: nil)
    @session.chat_messages.create!(role: role, content: content, kind: kind, user: (users(:one) if role == "user"))
  end

  test "it gives the person's messages and the replies, oldest first, without hidden requests, notes or the message answered" do
    said("user", "Add usage")
    said("assistant", "Added a usage chart.", kind: "summary")
    said("assistant", "Branch created", kind: "system")
    said("user", "Design as planned", kind: "request")
    said("assistant", "Which period? Proposal: 30 days", kind: "missing")
    current = said("user", "Make it weekly")

    assert_equal "The person: Add usage\n\nYou: Added a usage chart.\n\nYou asked: Which period? Proposal: 30 days",
                 Designs::ThreadHistory.text(@session, before: current.id)
  end

  # Each message below is 30 characters with its label: two of them and the
  # note that some were left out are past 70.
  test "past the limit the oldest messages go, and it says so" do
    %w[a b c].each { |letter| said("user", letter * 18) }
    current = said("user", "Next")

    assert_equal "(Earlier messages left out.)\n\nThe person: #{"c" * 18}",
                 Designs::ThreadHistory.text(@session, before: current.id, limit: 70)
  end

  test "a thread with nothing before the message has no history" do
    current = said("user", "First")

    assert_nil Designs::ThreadHistory.text(@session, before: current.id)
  end
end
