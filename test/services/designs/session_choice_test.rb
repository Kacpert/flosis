require "test_helper"

# Which Claude session a thread's turn runs in (2026-11-27): a build that
# answers a plan or a proposal goes on in its session; any other turn goes on
# only in a session that is warm and small, and starts a new one otherwise.
class Designs::SessionChoiceTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @thread = @project.design_threads.create!(author: users(:one), title: "T", branch: "design/t",
                                              chat_session: Designs::Threads.new_session(@project, users(:one)))
    @now = Time.zone.parse("2026-11-27 18:00")
  end

  # A turn of the thread, on a message of its own unless one is given.
  def turn(kind: "design", status: "queued", started: nil, finished: nil, context: nil, message: nil)
    message ||= @thread.chat_session.chat_messages.create!(role: "user", content: "Ask", user: users(:one))
    DesignTurn.create!(chat_session: @thread.chat_session, chat_message: message, kind: kind, status: status,
                       started_at: started, finished_at: finished, context_tokens: context)
  end

  # A turn that ran and finished minutes_ago, its context that large.
  def ran(minutes_ago:, context:, kind: "design")
    at = @now - minutes_ago.minutes
    turn(kind: kind, status: "succeeded", started: at - 1.minute, finished: at, context: context)
  end

  def choice(turn, renews: true) = Designs::SessionChoice.for(turn, renews: renews, now: @now)

  test "a chat's first turn starts its session" do
    assert_equal :start, choice(turn)
  end

  test "a build that answers a plan resumes the plan's session, however old or large" do
    ran(minutes_ago: 180, context: 400_000, kind: "plan")

    assert_equal :resume, choice(turn)
  end

  test "a later message resumes a session that is warm and small" do
    ran(minutes_ago: 10, context: 149_999)

    assert_equal :resume, choice(turn)
  end

  test "a later message renews a session gone cold" do
    ran(minutes_ago: 56, context: 10_000)
    assert_equal :renew, choice(turn)

    ran(minutes_ago: 54, context: 10_000)
    assert_equal :resume, choice(turn)
  end

  test "a later message renews a session past 150k tokens" do
    ran(minutes_ago: 1, context: 150_000)

    assert_equal :renew, choice(turn)
  end

  # Threads from before the size was kept: their sessions may be huge.
  test "a session whose size is unknown is renewed" do
    ran(minutes_ago: 1, context: nil)

    assert_equal :renew, choice(turn)
  end

  test "components and resolving turns always renew" do
    ran(minutes_ago: 1, context: 10_000)

    assert_equal :renew, choice(turn(kind: "components"))
    assert_equal :renew, choice(turn(kind: "resolve_conflicts"))
  end

  # A check runs in a session of its own (Designs::TurnJob#converse).
  test "a check does not count as the session's last turn" do
    ran(minutes_ago: 10, context: 10_000)
    ran(minutes_ago: 1, context: nil, kind: "check")

    assert_equal :resume, choice(turn)
  end

  test "Try again on a build that answered a plan still resumes the plan's session" do
    ran(minutes_ago: 120, context: 300_000, kind: "plan")
    answer = @thread.chat_session.chat_messages.create!(role: "user", content: "Use 30 days", user: users(:one))
    turn(status: "failed", started: @now - 100.minutes, finished: @now - 99.minutes, message: answer)

    assert_equal :resume, choice(turn(message: answer))
  end

  test "a subject that does not renew resumes as before" do
    ran(minutes_ago: 600, context: 900_000)

    assert_equal :resume, choice(turn, renews: false)
  end
end
