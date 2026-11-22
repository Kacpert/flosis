require "test_helper"

# SCRUM-70: every Claude run leaves an AiRun, whatever way it ends. These run
# a fake `claude` on the PATH, so the service's real process handling is what
# is tested.
class ClaudeCliServiceRecordingTest < ActiveSupport::TestCase
  include AiRunTestHelper
  include FakeClaudeBinTestHelper

  class StopError < StandardError
    include ClaudeCliService::StopSignal
  end

  INT_RESULT = CLI_RESULT.merge("subtype" => "error_during_execution", "is_error" => true, "total_cost_usd" => 0.25,
                                "result" => "").freeze
  ASSISTANT = { "type" => "assistant", "message" => { "id" => "m1", "model" => "claude-opus-5",
    "usage" => { "input_tokens" => 7, "output_tokens" => 3, "cache_read_input_tokens" => 70, "cache_creation_input_tokens" => 0 } } }.freeze

  def service(**options)
    ClaudeCliService.new(codebase_path: Dir.tmpdir, attribution: ai_attribution, **options)
  end

  test "a json run records tokens, cost and model" do
    with_fake_claude_bin(%(STDIN.read; puts #{CLI_RESULT.to_json.inspect})) do
      service.start_session(prompt: "hi")
    end

    run = AiRun.last
    assert_equal "succeeded", run.status
    assert_equal BigDecimal("0.5"), run.cost_usd
    assert_equal "claude-opus-5", run.model
    assert_equal "agents", run.area
    assert_equal "Test", run.automation
    assert_equal 15, run.input_tokens
    assert run.duration_ms
  end

  test "an is_error result records failed with its cost" do
    with_fake_claude_bin(%(STDIN.read; puts #{CLI_RESULT.merge("is_error" => true).to_json.inspect})) do
      service.start_session(prompt: "hi")
    end

    run = AiRun.last
    assert_equal "failed", run.status
    assert_equal BigDecimal("0.5"), run.cost_usd
  end

  test "a CLI error records failed and re-raises" do
    with_fake_claude_bin(%(STDIN.read)) do
      assert_raises(ClaudeCliService::ClaudeCliError) { service.start_session(prompt: "hi") }
    end

    run = AiRun.last
    assert_equal "failed", run.status
    assert_nil run.cost_usd
  end

  test "timeout records timed_out with cost" do
    script = %(trap("INT") { puts #{INT_RESULT.to_json.inspect}; exit 0 }\nSTDIN.read\nsleep 30)
    with_fake_claude_bin(script) do
      assert_raises(ClaudeCliService::TimeoutError) { service(timeout: 1).start_session(prompt: "hi") }
    end

    run = AiRun.last
    assert_equal "timed_out", run.status
    assert_equal BigDecimal("0.25"), run.cost_usd
  end

  test "stopped stream run records INT result cost" do
    script = %(trap("INT") { puts #{INT_RESULT.to_json.inspect}; exit 0 }\nSTDIN.read\nputs #{ASSISTANT.to_json.inspect}\nsleep 30)
    with_fake_claude_bin(script) do
      assert_raises(StopError) do
        service.start_session(prompt: "hi") { |event| raise StopError if event.is_a?(Hash) && event["type"] == "assistant" }
      end
    end

    run = AiRun.last
    assert_equal "stopped", run.status
    assert_equal BigDecimal("0.25"), run.cost_usd
    assert_equal 15, run.input_tokens
  end

  test "a stream run without a result keeps assistant tokens and unknown cost" do
    with_fake_claude_bin(%(STDIN.read; puts #{ASSISTANT.to_json.inspect})) do
      assert_raises(ClaudeCliService::ClaudeCliError) { service.start_session(prompt: "hi") { |_event| } }
    end

    run = AiRun.last
    assert_equal "failed", run.status
    assert_equal 7, run.input_tokens
    assert_equal 70, run.cache_read_tokens
    assert_nil run.cost_usd
  end

  test "chat client gone keeps draining and records the result" do
    script = %(STDIN.read\nputs #{ASSISTANT.to_json.inspect}\nsleep 0.2\nputs #{CLI_RESULT.to_json.inspect})
    with_fake_claude_bin(script) do
      assert_raises(IOError) { service.send_initial_streaming(prompt: "hi") { |_line| raise IOError, "client gone" } }
    end

    run = AiRun.last
    assert_equal "succeeded", run.status
    assert_equal BigDecimal("0.5"), run.cost_usd
  end

  test "a follow-up chat message records its run" do
    with_fake_claude_bin(%(STDIN.read; puts #{CLI_RESULT.to_json.inspect})) do
      result = service.send_message_streaming(session_id: "s1", message: "more") { |_line| }
      assert_equal "Done.", result[:response]
    end

    assert_equal BigDecimal("0.5"), AiRun.last.cost_usd
  end

  test "own key is only the project's own key" do
    project = projects(:jira_project)
    project.update!(anthropic_api_key: "sk-own")
    with_fake_claude_bin(%(STDIN.read; puts #{CLI_RESULT.to_json.inspect})) do
      service(api_key: "sk-own").start_session(prompt: "hi")
      assert AiRun.last.own_key

      service(api_key: "sk-other").start_session(prompt: "hi")
      refute AiRun.last.own_key

      service.start_session(prompt: "hi")
      refute AiRun.last.own_key
    end
  end

  test "attribution is required" do
    assert_raises(ArgumentError) { ClaudeCliService.new(codebase_path: "/tmp") }
    assert_raises(ArgumentError) { ClaudeCliService.new(codebase_path: "/tmp", attribution: nil) }
  end

  test "a recording failure never stops the run" do
    original = AiRun::Recorder.method(:start!)
    AiRun::Recorder.define_singleton_method(:start!) { |*, **| nil }
    with_fake_claude_bin(%(STDIN.read; puts #{CLI_RESULT.to_json.inspect})) do
      assert_equal "Done.", service.start_session(prompt: "hi")[:response]
    end
  ensure
    AiRun::Recorder.define_singleton_method(:start!, original)
  end

  # Final review: reading the project's key is part of recording, and must
  # never stop a run — not even one that never uses the key.
  test "a project key that cannot be read never stops the run" do
    project = projects(:jira_project)
    project.define_singleton_method(:anthropic_api_key) { raise ActiveRecord::Encryption::Errors::Decryption }
    with_fake_claude_bin(%(STDIN.read; puts #{CLI_RESULT.to_json.inspect})) do
      svc = ClaudeCliService.new(codebase_path: Dir.tmpdir, attribution: ai_attribution(project: project), api_key: "sk-x")
      assert_equal "Done.", svc.start_session(prompt: "hi")[:response]
    end
    refute AiRun.last.own_key
  end

end
