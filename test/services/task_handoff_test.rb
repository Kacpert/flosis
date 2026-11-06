require "test_helper"

# A task started from another task's conversation is handed what that
# conversation said about it, written by an AI that reads it.
class TaskHandoffTest < ActiveSupport::TestCase
  include FakeChatCliTestHelper

  setup do
    @source = flosis_task("Add token calculations")
    @source.update!(description: "Count the tokens every run uses.")
    @conversation = ChatSession.create!(task: @source, workspace: @source.project.workspace, user: users(:one),
                                        purpose: "refine", claude_session_id: "old-session", codebase_path: "/tmp")
    @conversation.chat_messages.create!(role: "assistant", content: "Should usage be shown per billing period?")
    @conversation.chat_messages.create!(role: "user", user: users(:one),
                                        content: "Yes, monthly. Joining two thirds in, you pay a third.")
    @task = @source.project.tasks.create!(name: "Billing", description: "Charge plans for the tokens they use.",
                                          spun_off_from: @source, handoff_chat_session: @conversation)
  end

  test "the AI reads the conversation for the new task, and what it hands over is kept" do
    with_scripted_cli("Done.\n<handoff>\n- Billed monthly, prorated on joining\n</handoff>") do |runs|
      TaskHandoff.new(@task).write!

      prompt = runs.first[:prompt]
      assert_includes prompt, "Billing"
      assert_includes prompt, "Charge plans for the tokens they use."
      assert_includes prompt, "«Add token calculations»"
      assert_includes prompt, "Count the tokens every run uses."
      assert_includes prompt, "**AI:** Should usage be shown per billing period?"
      assert_includes prompt, "**Kacper:** Yes, monthly. Joining two thirds in, you pay a third."
    end

    assert_equal "- Billed monthly, prorated on joining", @task.reload.handoff
    assert_not @task.handoff_pending?
  end

  test "the AI gets no tools and no code" do
    with_scripted_cli("<handoff>- Billed monthly</handoff>") do |runs|
      TaskHandoff.new(@task).write!

      assert_equal [], runs.first[:keywords][:allowed_tools]
      assert_equal ChatStreaming::NO_CODEBASE_DIR.to_s, runs.first[:keywords][:codebase_path]
    end
  end

  test "a conversation that says nothing about the new task hands over nothing" do
    with_scripted_cli("<handoff>\n</handoff>") { TaskHandoff.new(@task).write! }

    assert_equal "", @task.reload.handoff
    assert_not @task.handoff_pending?
  end

  test "a run that fails hands over the conversation as it was" do
    with_scripted_cli(ClaudeCliService::ClaudeCliError.new("Claude CLI not found")) { TaskHandoff.new(@task).write! }

    handoff = @task.reload.handoff
    assert_includes handoff, "could not be summarized"
    assert_includes handoff, "**Kacper:** Yes, monthly. Joining two thirds in, you pay a third."
  end

  test "a run that ends in an error hands over the conversation as it was" do
    with_scripted_cli({ "is_error" => true, "result" => "API Error: Overloaded" }) { TaskHandoff.new(@task).write! }

    handoff = @task.reload.handoff
    assert_includes handoff, "could not be summarized"
    assert_not_includes handoff, "Overloaded"
  end

  test "the caller hears keepalives while the AI works" do
    beats = 0
    with_scripted_cli("<handoff>- Billed monthly</handoff>") { TaskHandoff.new(@task).write! { beats += 1 } }

    assert_equal 1, beats
  end

  test "a handoff is written once" do
    @task.update!(handoff: "- Already handed over")

    with_scripted_cli do |runs|
      TaskHandoff.new(@task).write!
      assert_empty runs
    end
    assert_equal "- Already handed over", @task.reload.handoff
  end

  test "a task whose conversation was deleted waits for nothing" do
    @conversation.destroy!

    assert_not @task.reload.handoff_pending?
    with_scripted_cli do |runs|
      TaskHandoff.new(@task).write!
      assert_empty runs
    end
    assert_nil @task.reload.handoff
  end
end
