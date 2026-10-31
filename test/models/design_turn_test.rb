require "test_helper"

class DesignTurnTest < ActiveSupport::TestCase
  setup do
    task = tasks(:jira_task)
    @session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one),
                                   purpose: "designs", claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    @message = @session.chat_messages.create!(role: "user", content: "Add an archive tab", user: users(:one))
  end

  def turn(**attrs) = DesignTurn.create!({ chat_session: @session, chat_message: @message }.merge(attrs))

  test "a new turn is queued" do
    assert_equal "queued", turn.status
  end

  test "a turn moves through running to succeeded" do
    t = turn
    t.start!
    assert t.running?
    assert t.started_at
    t.succeed!(commit_sha: "abc123")
    assert t.succeeded?
    assert_equal "abc123", t.commit_sha
    assert t.finished_at
  end

  test "fail_stale! fails only running turns older than the timeout" do
    old = turn(status: "running", started_at: DesignTurn.stale_after.ago - 1.minute)
    fresh = turn(status: "running", started_at: 1.minute.ago)
    assert_equal 1, DesignTurn.fail_stale!
    assert old.reload.failed?
    assert_match(/Interrupted/, old.error)
    assert fresh.reload.running?
  end

  test "the designs api key never falls back to the server's key" do
    project = projects(:jira_project)
    project.update!(anthropic_api_key: nil)
    ENV["ANTHROPIC_API_KEY"] = "server-key"
    assert_nil ProjectCredentials.new(project).designs_api_key
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  # What the four tests above leave open: the rest of the interface Tasks 5-7
  # build on.

  test "a turn that fails keeps the reason and when it stopped" do
    t = turn
    t.start!
    t.fail!("Refused: .claude/skill.md")
    assert t.failed?
    assert_equal "Refused: .claude/skill.md", t.error
    assert t.finished_at
  end

  # The job records every error through fail! and never re-raises one. MySQL
  # refuses a TEXT past 65,535 bytes (Postgres would take it), so an error that
  # long is cut rather than left to raise from inside the handler.
  test "an error too long for the column is cut, not refused" do
    t = turn
    t.start!
    t.fail!("x" * 70_000)
    assert t.reload.failed?
    assert_operator t.error.bytesize, :<=, 65_535
    assert t.error.start_with?("xxx")
    assert t.error.end_with?("...")
  end

  # Claude can answer without touching a file, and that turn still succeeded.
  test "a turn that changed nothing succeeds with no commit" do
    t = turn
    t.start!
    t.succeed!(commit_sha: nil)
    assert t.succeeded?
    assert_nil t.commit_sha
  end

  # A retry puts a failed turn back in the queue and the job starts it again:
  # the row must not go on carrying how the last attempt ended.
  test "starting a turn again forgets how the last attempt ended" do
    t = turn
    t.start!
    t.fail!("Interrupted")
    t.update!(status: "queued")
    t.start!
    assert t.running?
    assert_nil t.error
    assert_nil t.finished_at
  end

  test "a new turn is a design turn" do
    assert_equal "design", turn.kind
  end

  test "a turn needs a status and a kind that Flosis knows" do
    odd_status = DesignTurn.new(chat_session: @session, chat_message: @message, status: "paused")
    assert_not odd_status.valid?
    assert_includes odd_status.errors[:status], "is not included in the list"

    odd_kind = DesignTurn.new(chat_session: @session, chat_message: @message, kind: "redesign")
    assert_not odd_kind.valid?
    assert_includes odd_kind.errors[:kind], "is not included in the list"

    assert turn(kind: "resolve_conflicts").persisted?
  end

  test "only queued and running turns are active" do
    %w[queued running succeeded failed].each { |status| turn(status: status) }
    assert_equal %w[queued running], DesignTurn.active.order(:id).pluck(:status)
  end

  # The CLI is given DESIGNS_TURN_TIMEOUT_SECONDS (15 minutes unless set);
  # committing, pushing and publishing get five more.
  test "a turn is stale five minutes after the CLI's timeout" do
    with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => nil) { assert_equal 20.minutes, DesignTurn.stale_after }
    with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => "60") { assert_equal 6.minutes, DesignTurn.stale_after }
  end

  # Ruling P2-R8: one reader for the CLI's timeout and for stale_after, so the
  # two cannot drift apart.
  test "a turn's time limit is DESIGNS_TURN_TIMEOUT_SECONDS when that is a positive whole number, else 15 minutes" do
    with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => nil) { assert_equal 900, DesignTurn.turn_timeout }
    with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => "120") { assert_equal 120, DesignTurn.turn_timeout }
    with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => "010") { assert_equal 10, DesignTurn.turn_timeout, "decimal, not octal" }
    [ "", "0", "-5", "1.5", "ten", "60s", "0x10" ].each do |value|
      with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => value) { assert_equal 900, DesignTurn.turn_timeout, value.inspect }
    end
    with_env("DESIGNS_TURN_TIMEOUT_SECONDS" => "ten") { assert_equal 20.minutes, DesignTurn.stale_after }
  end

  # Ruling P2-R12. The CLI refuses a cap that is not a positive number, and a
  # turn must not run uncapped.
  test "a turn's cost cap is DESIGNS_TURN_BUDGET_USD when that is a positive number, else 5 dollars" do
    with_env("DESIGNS_TURN_BUDGET_USD" => nil) { assert_equal 5, DesignTurn.turn_budget_usd }
    with_env("DESIGNS_TURN_BUDGET_USD" => "2.5") { assert_equal 2.5, DesignTurn.turn_budget_usd }
    with_env("DESIGNS_TURN_BUDGET_USD" => "12") { assert_equal 12, DesignTurn.turn_budget_usd }
    [ "", "0", "-1", "five", "Infinity", "1e400" ].each do |value|
      with_env("DESIGNS_TURN_BUDGET_USD" => value) { assert_equal 5, DesignTurn.turn_budget_usd, value.inspect }
    end
  end

  test "stale? is true only for a running turn past its limit" do
    too_long = DesignTurn.stale_after.ago - 1.minute
    assert turn(status: "running", started_at: too_long).stale?
    assert_not turn(status: "running", started_at: 1.minute.ago).stale?
    assert_not turn.stale?, "a queued turn has not started"
    assert_not turn(status: "failed", started_at: too_long).stale?, "a finished turn was not interrupted"
  end

  test "an interrupted turn says to retry it" do
    old = turn(status: "running", started_at: DesignTurn.stale_after.ago - 1.minute)
    DesignTurn.fail_stale!
    old.reload
    assert_equal "Interrupted before it finished — retry it.", old.error
    assert old.finished_at
    assert_operator old.updated_at, :>, old.created_at
  end

  # A retried turn can be queued again with the start time of its last attempt
  # still on it; only a turn that is running was cut off.
  test "fail_stale! leaves turns that are not running alone" do
    too_long = DesignTurn.stale_after.ago - 1.minute
    waiting = turn(started_at: too_long)
    done = turn(status: "succeeded", started_at: too_long)
    assert_equal 0, DesignTurn.fail_stale!
    assert waiting.reload.queued?
    assert done.reload.succeeded?
  end

  # design_turns.chat_message_id points at the message, so the turns have to be
  # destroyed before the messages are.
  test "destroying a chat session removes its turns and then its messages" do
    turn
    assert_difference [ "DesignTurn.count", "ChatMessage.count" ], -1 do
      @session.destroy!
    end
  end
end
