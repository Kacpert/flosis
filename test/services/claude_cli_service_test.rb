require "test_helper"
require "tmpdir"

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

  test "with an API key build_command adds --bare and popen_args returns the key as the environment" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, api_key: "sk-ant-test")
    assert_includes service.send(:build_command, streaming: false), "--bare"
    assert_equal [ { "ANTHROPIC_API_KEY" => "sk-ant-test", "CLAUDE_CODE_OAUTH_TOKEN" => nil, "ANTHROPIC_AUTH_TOKEN" => nil },
                   [ "claude" ] ],
                 service.send(:popen_args, [ "claude" ])
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

  test "a streaming resume with an API key still runs bare" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, api_key: "sk-ant-test")
    cmd = service.send(:build_command, session_id: "abc", streaming: true)

    assert_includes cmd, "--bare"
    assert_includes cmd.each_cons(2).to_a, [ "--resume", "abc" ]
  end

  # The next three run the real IO.popen, so they check what the Claude process
  # actually receives, not just what the private helpers return.

  test "run_claude with an API key puts the key in the Claude process environment" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, api_key: "sk-ant-test")

    assert_equal "sk-ant-test", service.send(:run_claude, [ "sh", "-c", 'printf %s "$ANTHROPIC_API_KEY"' ], "")
  end

  test "popen_streaming with an API key puts the key in the Claude process environment" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, api_key: "sk-ant-test")
    lines = []

    service.send(:popen_streaming, [ "sh", "-c", 'printf %s "$ANTHROPIC_API_KEY"' ], "") { |line| lines << line }

    assert_equal [ "sk-ant-test" ], lines - [ :keepalive ]
  end

  test "without an API key the Claude process inherits ANTHROPIC_API_KEY from the parent" do
    original = ENV["ANTHROPIC_API_KEY"]
    begin
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-parent"
      service = ClaudeCliService.new(codebase_path: Dir.tmpdir)

      assert_equal "sk-ant-parent", service.send(:run_claude, [ "sh", "-c", 'printf %s "$ANTHROPIC_API_KEY"' ], "")
    ensure
      if original
        ENV["ANTHROPIC_API_KEY"] = original
      else
        ENV.delete("ANTHROPIC_API_KEY")
      end
    end
  end

  # The server's own Claude login can sit in the environment the app runs
  # with. A keyed run is billed to the project's key alone, so the variables
  # that carry that login never reach it; a run without a key keeps them.
  test "a keyed Claude process does not inherit the server's login from the environment" do
    probe = [ "sh", "-c", 'printf "%s|%s" "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "${ANTHROPIC_AUTH_TOKEN-unset}"' ]
    with_env("CLAUDE_CODE_OAUTH_TOKEN" => "oauth-from-parent", "ANTHROPIC_AUTH_TOKEN" => "auth-from-parent") do
      keyed = ClaudeCliService.new(codebase_path: Dir.tmpdir, api_key: "sk-ant-test")
      assert_equal "unset|unset", keyed.send(:run_claude, probe, "")
      lines = []
      keyed.send(:popen_streaming, probe, "") { |line| lines << line }
      assert_equal [ "unset|unset" ], lines - [ :keepalive ]

      keyless = ClaudeCliService.new(codebase_path: Dir.tmpdir)
      assert_equal "oauth-from-parent|auth-from-parent", keyless.send(:run_claude, probe, "")
    end
  end

  # -- the guard rails a design turn needs --

  test "a design turn's command carries every guard rail" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, api_key: "k", restricted: true,
                                   append_system_prompt_file: "/tmp/p.md", add_dirs: [ "/srv/app" ],
                                   max_budget_usd: "5", allowed_tools: %w[Read Glob Grep Edit Write])
    cmd = service.send(:build_command, streaming: false)
    assert_includes cmd, "--restricted"
    assert_equal "/tmp/p.md", cmd[cmd.index("--append-system-prompt-file") + 1]
    assert_equal "/srv/app", cmd[cmd.index("--add-dir") + 1]
    assert_equal "5", cmd[cmd.index("--max-budget-usd") + 1]
    assert_equal %w[Read Glob Grep Edit Write], cmd.each_cons(2).select { |a, _| a == "--allowedTools" }.map(&:last)
  end

  test "a new session can be given its id up front" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: false, new_session_id: "11111111-2222-3333-4444-555555555555")
    assert_equal "11111111-2222-3333-4444-555555555555", cmd[cmd.index("--session-id") + 1]
  end

  # Every existing caller passes none of the new options.
  test "without the new options the command is exactly what it was" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    allowed = ClaudeCliService::ALLOWED_TOOLS.flat_map { |tool| [ "--allowedTools", tool ] }

    assert_equal [ "claude", "-p", "--output-format", "json", *allowed ], service.send(:build_command, streaming: false)
    assert_equal [ "claude", "-p", "--output-format", "stream-json", "--verbose", "--resume", "abc", *allowed ],
                 service.send(:build_command, session_id: "abc", streaming: true)
  end

  test "the guard rails are the service's, so a streaming run carries them too" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, restricted: true, add_dirs: [ "/srv/app" ])
    cmd = service.send(:build_command, session_id: "abc", streaming: true)

    assert_includes cmd, "--restricted"
    assert_includes cmd.each_cons(2).to_a, [ "--add-dir", "/srv/app" ]
  end

  test "--add-dir is given once per directory, in the order they were passed" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, add_dirs: [ "/srv/app", "/srv/shared" ])
    cmd = service.send(:build_command, streaming: false)

    assert_equal [ [ "--add-dir", "/srv/app" ], [ "--add-dir", "/srv/shared" ] ],
                 cmd.each_cons(2).select { |flag, _| flag == "--add-dir" }
  end

  # IO.popen takes strings only, so a number has to reach the command as one.
  test "the budget may be given as a number" do
    [ [ 5, "5" ], [ 2.5, "2.5" ] ].each do |given, expected|
      cmd = ClaudeCliService.new(codebase_path: @codebase_path, max_budget_usd: given).send(:build_command, streaming: false)

      assert_equal expected, cmd[cmd.index("--max-budget-usd") + 1]
    end
  end

  # A cap that was asked for must not quietly become "no cap": a blank budget would
  # simply leave the flag off, and Timeout.timeout(0) means "no timeout".
  test "a budget or a timeout that is given but unusable is refused, never quietly dropped" do
    [ "", "  ", "abc", 0, "0", -1, "-2" ].each do |budget|
      error = assert_raises(ArgumentError, "max_budget_usd: #{budget.inspect}") do
        ClaudeCliService.new(codebase_path: @codebase_path, max_budget_usd: budget)
      end
      assert_match(/\Amax_budget_usd must be a positive number of dollars, got /, error.message)
    end

    [ 0, -1, "900", "", Float::NAN ].each do |timeout|
      error = assert_raises(ArgumentError, "timeout: #{timeout.inspect}") do
        ClaudeCliService.new(codebase_path: @codebase_path, timeout: timeout)
      end
      assert_match(/\Atimeout must be a positive number of seconds, got /, error.message)
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

  test "start_session names the session up front when given an id" do
    id = "11111111-2222-3333-4444-555555555555"
    service, ran = recording_service({ "type" => "result", "result" => "Hi", "session_id" => id }.to_json)

    result = service.start_session(prompt: "Make a login page", new_session_id: id)

    assert_equal id, ran[:cmd][ran[:cmd].index("--session-id") + 1]
    assert_equal "Make a login page", ran[:message]
    assert_equal({ session_id: id, response: "Hi", is_error: false }, result)
  end

  # Ruling P2-R29. An API error (an overload past the CLI's own retries, say)
  # ends the run with is_error set and the error as its result, an answer in
  # form only. The cost cap ends it with no result at all.
  test "a run that ended in an error says so" do
    overloaded = { "type" => "result", "subtype" => "success", "is_error" => true,
                   "result" => "API Error: 529 Overloaded", "session_id" => "s" }.to_json
    assert_equal({ session_id: "s", response: "API Error: 529 Overloaded", is_error: true },
                 build_fake_service(run_claude_output: overloaded).start_session(prompt: "Hi"))

    capped = { "type" => "result", "subtype" => "error_max_budget_usd", "is_error" => true, "session_id" => "s" }.to_json
    assert_equal({ session_id: "s", response: "", is_error: true },
                 build_fake_service(run_claude_output: capped).resume_session(session_id: "s", prompt: "Hi"))

    answered = { "type" => "result", "is_error" => false, "result" => "Done.", "session_id" => "s" }.to_json
    assert_equal false, build_fake_service(run_claude_output: answered).start_session(prompt: "Hi")[:is_error]
  end

  test "start_session without an id leaves the naming to the CLI" do
    service, ran = recording_service({ "result" => "Hi", "session_id" => "s" }.to_json)

    service.start_session(prompt: "Hello")

    refute_includes ran[:cmd], "--session-id"
  end

  # -- resume_session tests --

  test "resume_session resumes the session without streaming and returns the answer" do
    service, ran = recording_service({ "type" => "result", "result" => "Done.", "session_id" => "abc" }.to_json,
                                     restricted: true)

    result = service.resume_session(session_id: "abc", prompt: "Now the settings page")

    pairs = ran[:cmd].each_cons(2).to_a
    assert_includes pairs, [ "--resume", "abc" ]
    assert_includes pairs, [ "--output-format", "json" ]
    refute_includes ran[:cmd], "--verbose"
    assert_includes ran[:cmd], "--restricted", "a resumed turn keeps the service's guard rails"
    assert_equal "Now the settings page", ran[:message]
    assert_equal({ session_id: "abc", response: "Done.", is_error: false }, result)
  end

  # The CLI prints "No conversation found with session ID: ..." on stderr and
  # nothing on stdout when it cannot find the session.
  test "resume_session raises ClaudeCliError when the CLI printed no answer" do
    service, = recording_service("")

    assert_raises(ClaudeCliService::ClaudeCliError) { service.resume_session(session_id: "gone", prompt: "Hi") }
  end

  test "resume_session reports a missing CLI as ClaudeCliError" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    service.define_singleton_method(:run_claude) { |_cmd, _message| raise Errno::ENOENT }

    error = assert_raises(ClaudeCliService::ClaudeCliError) { service.resume_session(session_id: "abc", prompt: "Hi") }
    assert_match(/not found/, error.message)
  end

  # -- timeout tests (these run real processes) --

  test "a run past its timeout is killed and raises" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 0.3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(ClaudeCliService::TimeoutError) { service.send(:run_claude, [ "sleep", "10" ], "") }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 7
  end

  test "a run that finishes within its timeout returns its output" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 30)

    assert_equal "hello", service.send(:run_claude, [ "cat" ], "hello")
  end

  # sleep never reads its stdin, so a prompt this size blocks in the write.
  test "the timeout covers handing over the prompt as well" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 0.3)
    started = monotonic

    assert_raises(ClaudeCliService::TimeoutError) { service.send(:run_claude, [ "sleep", "10" ], "x" * 1_000_000) }
    assert_operator monotonic - started, :<, 7
  end

  test "the timeout error says how long the run was given" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 0.3)

    error = assert_raises(ClaudeCliService::TimeoutError) { service.send(:run_claude, [ "sleep", "10" ], "") }
    assert_includes error.message, "0.3 seconds"
  end

  test "a child is told to stop with TERM first, so it can clean up" do
    script = <<~'SH'
      trap 'echo terminated > "$0"; exit 0' TERM
      echo ready
      while :; do sleep 0.05; done
    SH

    Dir.mktmpdir do |dir|
      marker = File.join(dir, "terminated")
      with_child([ "sh", "-c", script, marker ]) do |child|
        assert_equal "ready\n", child.gets, "the trap is in place from here on"
        ClaudeCliService.new(codebase_path: Dir.tmpdir).send(:stop_child, child.pid)
      end

      assert_equal "terminated\n", File.read(marker)
    end
  end

  test "a child that ignores TERM is killed once the grace period is over" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir)

    with_child([ "sh", "-c", 'trap "" TERM; echo ready; exec sleep 30' ]) do |child|
      assert_equal "ready\n", child.gets, "TERM is ignored from here on"
      started = monotonic
      service.send(:stop_child, child.pid, grace: 0.3)
      elapsed = monotonic - started

      assert_operator elapsed, :>=, 0.2, "it was given its grace period, not killed at once"
      assert_operator elapsed, :<, 5
      assert_raises(Errno::ESRCH) { Process.kill(0, child.pid) }
    end
  end

  test "a child that has already exited is just collected" do
    IO.popen([ "sh", "-c", "exit 0" ]) do |child|
      child.read # EOF: the child is done, though nobody has waited for it yet

      assert_nothing_raised { ClaudeCliService.new(codebase_path: Dir.tmpdir).send(:stop_child, child.pid) }
    end
  end

  test "a child somebody else already collected is not an error" do
    IO.popen([ "sh", "-c", "exit 0" ]) do |child|
      child.read
      Process.wait(child.pid)

      assert_nothing_raised { ClaudeCliService.new(codebase_path: Dir.tmpdir).send(:stop_child, child.pid) }
    end
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

  # -- a design turn's exact tool set --

  test "a run can be given its exact set of tools, which leaves out every other one" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, tools: %w[Read Glob Grep Edit Write])
    cmd = service.send(:build_command, streaming: true)

    assert_equal "Read,Glob,Grep,Edit,Write", cmd[cmd.index("--tools") + 1]
  end

  # -- a session run with a block streams its events --

  test "a session run with a block streams: each event is handed over as it comes, and the answer is returned" do
    events = [
      assistant("msg_1", { "type" => "text", "text" => "Let me look." }),
      assistant("msg_1", { "type" => "tool_use", "id" => "t1", "name" => "Read", "input" => { "file_path" => "/w/a.html" } }),
      { "type" => "user", "message" => { "content" => [ { "type" => "tool_result", "tool_use_id" => "t1", "content" => "x" } ] } },
      assistant("msg_2", { "type" => "text", "text" => "<summary>Done</summary>" }),
      { "type" => "result", "subtype" => "success", "is_error" => false, "result" => "<summary>Done</summary>", "session_id" => "s-1" }
    ]
    service, ran = streaming_service(events)
    seen = []

    answer = service.start_session(prompt: "Hi", new_session_id: "s-1") { |event| seen << event }

    assert_equal events, seen.reject { |event| event == :tick }
    assert_equal({ session_id: "s-1", response: "<summary>Done</summary>", is_error: false, subtype: "success",
                   final_text: "<summary>Done</summary>", final_tool_use: false }, answer)
    assert_equal "stream-json", ran[:cmd][ran[:cmd].index("--output-format") + 1]
    assert_equal "s-1", ran[:cmd][ran[:cmd].index("--session-id") + 1]
    assert_equal "Hi", ran[:message]
  end

  # The cost cap ends a run with no text: what Claude said last is all there is of its answer.
  test "a streamed run the cost cap ended keeps what Claude said last" do
    events = [
      assistant("msg_1", { "type" => "text", "text" => "<summary>Built the screen</summary>" }),
      { "type" => "result", "subtype" => "error_max_budget_usd", "is_error" => true, "errors" => [ "Reached maximum budget ($5)" ], "session_id" => "s-1" }
    ]
    service, = streaming_service(events)

    answer = service.resume_session(session_id: "s-1", prompt: "Hi") { |_event| }

    assert_equal "", answer[:response]
    assert_equal true, answer[:is_error]
    assert_equal "error_max_budget_usd", answer[:subtype]
    assert_equal "<summary>Built the screen</summary>", answer[:final_text]
    assert_equal false, answer[:final_tool_use]
  end

  test "Claude's last words are its last message's, which may have gone on to use a tool" do
    events = [
      assistant("msg_1", { "type" => "text", "text" => "First" }),
      assistant("msg_2", { "type" => "text", "text" => "Now " }),
      assistant("msg_2", { "type" => "text", "text" => "writing" }),
      assistant("msg_2", { "type" => "tool_use", "id" => "t2", "name" => "Write", "input" => {} }),
      { "type" => "result", "subtype" => "error_max_budget_usd", "is_error" => true, "session_id" => "s-1" }
    ]
    service, = streaming_service(events)

    answer = service.start_session(prompt: "Hi") { |_event| }

    assert_equal "Now writing", answer[:final_text]
    assert_equal true, answer[:final_tool_use]
  end

  test "a subagent's messages are never taken for Claude's last words" do
    events = [
      assistant("msg_1", { "type" => "text", "text" => "<summary>Mine</summary>" }),
      assistant("msg_9", { "type" => "text", "text" => "The subagent's" }).merge("parent_tool_use_id" => "t1"),
      { "type" => "result", "subtype" => "success", "is_error" => false, "result" => "<summary>Mine</summary>", "session_id" => "s-1" }
    ]
    service, = streaming_service(events)

    assert_equal "<summary>Mine</summary>", service.start_session(prompt: "Hi") { |_event| }[:final_text]
  end

  test "a resumed session streams too" do
    service, ran = streaming_service([ { "type" => "result", "subtype" => "success", "result" => "ok", "session_id" => "abc" } ])

    assert_equal "ok", service.resume_session(session_id: "abc", prompt: "Hi") { |_event| }[:response]
    assert_equal "abc", ran[:cmd][ran[:cmd].index("--resume") + 1]
    assert_includes ran[:cmd], "stream-json"
  end

  # A session the CLI cannot resume, or an id it will not start, prints no result.
  test "a streamed run that ends without a result raises ClaudeCliError" do
    service, = streaming_service([ { "type" => "system", "subtype" => "init" } ])

    assert_raises(ClaudeCliService::ClaudeCliError) { service.start_session(prompt: "Hi") { |_event| } }
  end

  # -- stream_claude (these run real processes) --

  test "stream_claude hands over each JSON line the CLI prints, and skips what is not JSON" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 30)
    script = %q(cat > /dev/null; printf '%s\n' '{"type":"a"}' 'noise' '{"type":"b","n":1}')
    seen = []

    service.send(:stream_claude, [ "sh", "-c", script ], "the prompt") { |event| seen << event }

    assert_equal [ { "type" => "a" }, { "type" => "b", "n" => 1 } ], seen.reject { |event| event == :tick }
  end

  test "stream_claude ticks while the CLI is quiet, so the caller can look up from waiting" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 30)
    seen = []

    service.send(:stream_claude, [ "sh", "-c", %q(sleep 0.5; printf '{"type":"a"}\n') ], "", tick: 0.1) { |event| seen << event }

    assert_operator seen.index(:tick), :<, seen.index({ "type" => "a" })
  end

  test "a streamed run past its timeout is stopped and raises" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 0.3)
    started = monotonic

    error = assert_raises(ClaudeCliService::TimeoutError) { service.send(:stream_claude, [ "sleep", "10" ], "") { |_event| } }
    assert_includes error.message, "0.3 seconds"
    assert_operator monotonic - started, :<, 7
  end

  test "the streamed run's timeout covers handing over the prompt as well" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 0.3)
    started = monotonic

    assert_raises(ClaudeCliService::TimeoutError) { service.send(:stream_claude, [ "sleep", "10" ], "x" * 1_000_000) { |_event| } }
    assert_operator monotonic - started, :<, 7
  end

  # How a turn is stopped on request: its block raises, and the CLI must not run on.
  test "an error the caller's block raises stops the CLI and goes up to the caller" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 30)
    started = monotonic

    assert_raises(ArgumentError) do
      service.send(:stream_claude, [ "sh", "-c", %q(printf '{"type":"a"}\n'; sleep 10) ], "") { |_event| raise ArgumentError, "stop" }
    end
    assert_operator monotonic - started, :<, 7
  end

  test "stream_claude reports a missing CLI as ClaudeCliError" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 30)

    assert_raises(ClaudeCliService::ClaudeCliError) { service.send(:stream_claude, [ "/nonexistent/claude-cli" ], "") { |_event| } }
  end

  # -- Error class tests --

  test "ClaudeCliError is a StandardError" do
    error = ClaudeCliService::ClaudeCliError.new("test")
    assert_kind_of StandardError, error
  end

  # The jobs rescue ClaudeCliError; a run that timed out is one of those.
  test "TimeoutError is a ClaudeCliError" do
    assert_operator ClaudeCliService::TimeoutError, :<, ClaudeCliService::ClaudeCliError
  end

  private

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Runs argv as a child process for the block. Whatever the block does, the child is
  # gone afterwards: IO.popen waits for its child when the block ends, so one that
  # outlived a failing test would hang the whole run.
  def with_child(argv)
    child = IO.popen(argv)
    yield child
  ensure
    if child
      begin
        Process.kill("KILL", child.pid) unless Process.wait(child.pid, Process::WNOHANG)
      rescue Errno::ESRCH, Errno::ECHILD
        nil # the code under test has already collected it
      end
      child.close
    end
  end

  # A service whose run_claude only records what it was given and answers with
  # `answer`: [ service, ran ], with ran[:cmd] and ran[:message] filled in by a run.
  def recording_service(answer, **options)
    ran = {}
    service = ClaudeCliService.new(codebase_path: @codebase_path, **options)
    service.define_singleton_method(:run_claude) do |cmd, message|
      ran[:cmd] = cmd
      ran[:message] = message
      answer
    end
    [ service, ran ]
  end

  # One content block of an assistant message, as the CLI streams it.
  def assistant(id, block)
    { "type" => "assistant", "message" => { "id" => id, "role" => "assistant", "content" => [ block ] } }
  end

  # A service whose stream_claude yields `events` and records what it was given:
  # [ service, ran ], with ran[:cmd] and ran[:message] filled in by a run.
  def streaming_service(events, **options)
    ran = {}
    service = ClaudeCliService.new(codebase_path: @codebase_path, **options)
    service.define_singleton_method(:stream_claude) do |cmd, message, **_opts, &block|
      ran[:cmd] = cmd
      ran[:message] = message
      events.each { |event| block.call(event) }
    end
    # Never the real CLI: a run that did not stream fails here instead.
    service.define_singleton_method(:run_claude) { |*| raise "a run given a block must stream" }
    [ service, ran ]
  end

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

  # A CLI that fails at once (a session it cannot resume) may quit before it
  # reads a long prompt: that is a run with no answer, which a turn can start
  # afresh, not a broken pipe.
  test "a CLI that quits before reading the prompt streams nothing, and the write does not fail" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 30)
    seen = []

    service.send(:stream_claude, [ "sh", "-c", "exit 0" ], "x" * 1_000_000) { |event| seen << event }

    assert_equal [], seen.reject { |event| event == :tick }
  end
end
