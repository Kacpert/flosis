require "test_helper"

class ClaudeCliServiceTest < ActiveSupport::TestCase
  setup do
    @codebase_path = "/tmp/test-codebase"
  end

  # codebase_path is not a flag. --add-dir was dropped in be2e014, and the only
  # thing the service does with the path now is run the subprocess in it — so
  # the directory the CLI is handed is the chdir, and nothing else.
  def chdir_for(service)
    captured = nil
    io = Object.new
    io.define_singleton_method(:write) { |_| }
    io.define_singleton_method(:close_write) { }
    io.define_singleton_method(:read) { "{}" }

    original = IO.method(:popen)
    IO.define_singleton_method(:popen) do |_cmd, _mode = "r", **opts, &block|
      captured = opts[:chdir]
      block.call(io)
    end
    service.send(:run_claude, [ "claude" ], "hello")
    captured
  ensure
    IO.define_singleton_method(:popen, original)
  end

  # -- build_command tests --

  test "build_command includes resume flag when session_id provided" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, session_id: "abc-123", streaming: false)

    assert_kind_of Array, cmd
    assert_includes cmd, "--resume"
    assert_includes cmd, "abc-123"
    assert_equal @codebase_path, chdir_for(service)
  end

  test "build_command uses array form not string" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: true)

    assert_kind_of Array, cmd
    assert_equal "claude", cmd.first
    assert_includes cmd, "--output-format"
    assert_includes cmd, "stream-json"
  end

  test "build_command without session_id does not include resume flag" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: false)

    assert_kind_of Array, cmd
    refute_includes cmd, "--resume"
  end

  test "build_command non-streaming uses json output format" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: false)

    assert_includes cmd, "--output-format"
    assert_includes cmd, "json"
    refute_includes cmd, "stream-json"
  end

  test "build_command streaming includes verbose flag" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: true)

    assert_includes cmd, "--verbose"
  end

  test "build_command always includes -p flag" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: false)

    assert_includes cmd, "-p"
  end

  test "with an API key the CLI runs bare and gets the key in its environment" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, api_key: "sk-ant-test")
    assert_includes service.send(:build_command, streaming: false), "--bare"
    assert_equal [ { "ANTHROPIC_API_KEY" => "sk-ant-test" }, [ "claude" ] ], service.send(:popen_args, [ "claude" ])
  end

  test "without an API key the command and the environment are unchanged" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    refute_includes service.send(:build_command, streaming: false), "--bare"
    assert_equal [ [ "claude" ] ], service.send(:popen_args, [ "claude" ])
  end

  test "an API key that is given but blank is refused, never a silent fallback to the server login" do
    [ "", "  " ].each do |blank|
      error = assert_raises(ArgumentError) { ClaudeCliService.new(codebase_path: @codebase_path, api_key: blank) }
      assert_equal "api_key was given but is blank — refusing to fall back to the server's Claude login", error.message
    end
  end

  test "uses codebase_path from initializer" do
    service = ClaudeCliService.new(codebase_path: "/custom/path")

    assert_equal "/custom/path", chdir_for(service)
  end

  test "uses default codebase path from ENV when none provided" do
    original_env = ENV["CHAT_CODEBASE_PATH"]
    begin
      ENV["CHAT_CODEBASE_PATH"] = "/env/codebase"

      assert_equal "/env/codebase", chdir_for(ClaudeCliService.new)
    ensure
      if original_env
        ENV["CHAT_CODEBASE_PATH"] = original_env
      else
        ENV.delete("CHAT_CODEBASE_PATH")
      end
    end
  end

  # -- start_session JSON parsing tests (using testable subclass) --

  test "start_session returns session_id and response" do
    fake_result = {
      "type" => "result",
      "subtype" => "success",
      "result" => "I've read the ticket. How can I help?",
      "session_id" => "fake-uuid-123"
    }.to_json

    service = build_fake_service(run_claude_output: fake_result)
    result = service.start_session(prompt: "Help with ticket DEV-1")

    assert_equal "fake-uuid-123", result[:session_id]
    assert_equal "I've read the ticket. How can I help?", result[:response]
  end

  test "start_session raises ClaudeCliError on invalid JSON" do
    service = build_fake_service(run_claude_output: "not valid json")

    assert_raises(ClaudeCliService::ClaudeCliError) do
      service.start_session(prompt: "test")
    end
  end

  test "start_session extracts empty response when result key is nil" do
    fake_result = {
      "type" => "result",
      "session_id" => "sess-1"
    }.to_json

    service = build_fake_service(run_claude_output: fake_result)
    result = service.start_session(prompt: "test")

    assert_equal "sess-1", result[:session_id]
    assert_equal "", result[:response]
  end

  # -- send_message_streaming tests (using testable subclass) --

  test "send_message_streaming yields lines and returns result" do
    line1 = { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "Hello" }] } }.to_json
    line2 = { "type" => "result", "result" => "Hello", "session_id" => "abc" }.to_json

    service = build_fake_service(streaming_lines: [ line1, line2 ])
    collected = []

    result = service.send_message_streaming(session_id: "abc", message: "Hi") do |line|
      collected << line
    end

    assert_equal 2, collected.length
    assert_equal "abc", result[:session_id]
    assert_equal "Hello", result[:response]
  end

  test "send_message_streaming preserves session_id when result has no session_id" do
    line1 = { "type" => "result", "result" => "Done" }.to_json

    service = build_fake_service(streaming_lines: [ line1 ])

    result = service.send_message_streaming(session_id: "original-id", message: "Hi") {}

    assert_equal "original-id", result[:session_id]
  end

  # -- Error class tests --

  test "ClaudeCliError is a StandardError" do
    error = ClaudeCliService::ClaudeCliError.new("test")
    assert_kind_of StandardError, error
  end

  private

  # Build a testable subclass that overrides IO interactions
  def build_fake_service(run_claude_output: nil, streaming_lines: nil)
    service = ClaudeCliService.new(codebase_path: @codebase_path)

    if run_claude_output
      service.define_singleton_method(:run_claude) { |_cmd, _message| run_claude_output }
    end

    if streaming_lines
      service.define_singleton_method(:popen_streaming) do |_cmd, _message, &block|
        streaming_lines.each { |line| block.call(line) }
      end
    end

    service
  end
end
