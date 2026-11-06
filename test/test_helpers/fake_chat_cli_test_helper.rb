# The Briefing, Details and Breakdown chats stream from the Claude CLI. These
# tests never run it: ClaudeCliService.new hands back a stand-in that streams
# nothing, and the keywords the chat built it with are kept for the test.
module FakeChatCliTestHelper
  def with_fake_cli
    captured = {}
    fake = Object.new
    fake.define_singleton_method(:send_initial_streaming) { |**| nil }
    original = ClaudeCliService.method(:new)
    ClaudeCliService.define_singleton_method(:new) { |**keywords| captured.merge!(keywords); fake }
    yield captured
  ensure
    ClaudeCliService.define_singleton_method(:new, original)
  end

  # Like with_fake_cli, but each run answers: a String is its final text, a
  # Hash is its result event, an exception is raised instead. Each run keeps
  # the keywords its service was built with, the prompt it was given, and
  # when (:turn, from 1) among the runs that were given one.
  def with_scripted_cli(*answers)
    runs = []
    turns = 0
    original = ClaudeCliService.method(:new)
    ClaudeCliService.define_singleton_method(:new) do |**keywords|
      run = { keywords: keywords }
      runs << run
      Object.new.tap do |fake|
        fake.define_singleton_method(:send_initial_streaming) do |prompt:, &block|
          run[:prompt] = prompt
          run[:turn] = turns += 1
          answer = answers.shift
          raise answer if answer.is_a?(Exception)

          block&.call(:keepalive)
          event = { "type" => "result", "session_id" => "session-#{runs.size}" }
          event.merge!(answer.is_a?(Hash) ? answer : { "result" => answer })
          block&.call(event.to_json)
        end
      end
    end
    yield runs
  ensure
    ClaudeCliService.define_singleton_method(:new, original)
  end

  # A chat controller as a request would have it (its prompt reads params),
  # holding the task, to build its prompt.
  def chat_controller(klass, task)
    klass.new.tap do |controller|
      controller.set_request!(ActionDispatch::TestRequest.create)
      controller.instance_variable_set(:@task, task)
    end
  end

  # A Workshop project of workspace one with no Jira, named and described as
  # Flosis is, and a task on it.
  def flosis_task(name = "Archive offers")
    project = projects(:plain_project)
    project.update!(name: "Flosis", context_info: "Time tracking and Workshop", show_in_workshop: true, external_type: nil)
    project.tasks.create!(name: name)
  end
end
