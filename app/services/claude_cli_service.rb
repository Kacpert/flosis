require "timeout"

class ClaudeCliService
  CLAUDE_CMD = "claude".freeze
  DEFAULT_CODEBASE_PATH = File.expand_path("~/work/elvium").freeze
  # What a run that is out of time gets to wind down after TERM, before it is killed.
  KILL_GRACE_SECONDS = 5
  # How often a streamed run looks up from a CLI that prints nothing, in seconds
  # (see stream_claude).
  TICK_SECONDS = 2

  def initialize(codebase_path: nil, allowed_tools: nil, model: nil, mcp_config: nil, api_key: nil,
                 restricted: false, append_system_prompt_file: nil, add_dirs: [], max_budget_usd: nil, timeout: nil,
                 tools: nil)
    @codebase_path = codebase_path || ENV.fetch("CHAT_CODEBASE_PATH", DEFAULT_CODEBASE_PATH)
    # Per-chat override of the pre-approved tool list. The briefing chat passes a
    # code-free set (no Read/Glob/Grep) so it stays a product conversation and
    # can't cite the codebase; other chats keep the full default.
    @allowed_tools = allowed_tools || ALLOWED_TOOLS
    # Optional model override (e.g. a cheaper model for a big one-off batch).
    # nil = the CLI's default model.
    @model = model
    # Optional path to a per-project .mcp.json. When set, the CLI loads ONLY
    # those MCP servers (--strict-mcp-config), giving per-project github/jira
    # tools with full isolation from the global config.
    @mcp_config = mcp_config
    # Optional Anthropic API key for this run. With one, the CLI runs --bare and
    # is handed the key as its only credential (see build_command and popen_args).
    # nil = the server's own CLI login, as before. A key that is given but blank
    # is refused rather than quietly becoming that login.
    if !api_key.nil? && api_key.blank?
      raise ArgumentError, "api_key was given but is blank — refusing to fall back to the server's Claude login"
    end
    @api_key = api_key
    # Restricted mode (--restricted): the CLI drops the tools that run commands or
    # code, and WebFetch, ignores the user/project/local settings files, and keeps
    # its file tools inside the working directories (add_dirs included).
    @restricted = restricted
    # Optional file whose text the CLI appends to its system prompt
    # (--append-system-prompt-file).
    @append_system_prompt_file = append_system_prompt_file
    # Directories besides the working one that the file tools may reach
    # (--add-dir, one flag per directory).
    @add_dirs = Array(add_dirs)
    # Optional cap on what one run may cost, in dollars (--max-budget-usd), and on
    # how long one run may take, in seconds (enforced by run_claude, so it covers
    # the non-streaming runs). nil = no cap. A cap that is given but unusable is
    # refused rather than quietly dropped: a blank budget would leave the flag off,
    # and Timeout.timeout treats 0 as "no timeout".
    unless max_budget_usd.nil? || Float(max_budget_usd.to_s, exception: false)&.positive?
      raise ArgumentError, "max_budget_usd must be a positive number of dollars, got #{max_budget_usd.inspect}"
    end
    unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.positive?)
      raise ArgumentError, "timeout must be a positive number of seconds, got #{timeout.inspect}"
    end
    @max_budget_usd = max_budget_usd
    @timeout = timeout
    # Optional exact set of built-in tools the run has (--tools): every other one
    # is left out, the subagent among them. nil = the CLI's own set, as before.
    @tools = tools
  end

  # Start a new Claude session with an initial prompt. A new_session_id (a UUID)
  # names the session up front (--session-id), so the caller has it before the run
  # is over and resume_session can find it later.
  # Returns { session_id: String, response: String, is_error: Boolean }
  #
  # With a block, the run streams: each event the CLI prints is handed to the
  # block as it comes, and :tick while it prints nothing (see stream_session for
  # what is returned then).
  def start_session(prompt:, new_session_id: nil, &on_event)
    return stream_session(build_command(streaming: true, new_session_id: new_session_id), prompt, &on_event) if on_event

    run_session(build_command(streaming: false, new_session_id: new_session_id), prompt)
  end

  # Send a message to an existing session and return the whole answer once the
  # run is over (send_message_streaming is the line-by-line variant). A session the
  # CLI cannot find prints nothing on stdout, which raises ClaudeCliError.
  # Returns { session_id: String, response: String, is_error: Boolean }
  # With a block, the run streams, as start_session's does.
  def resume_session(session_id:, prompt:, &on_event)
    return stream_session(build_command(session_id: session_id, streaming: true), prompt, &on_event) if on_event

    run_session(build_command(session_id: session_id, streaming: false), prompt)
  end

  # Start a brand-new session with the given prompt, streaming raw JSON lines
  # back to the caller. Yields :keepalive periodically so the caller can
  # write SSE keepalives.
  def send_initial_streaming(prompt:, &block)
    cmd = build_command(streaming: true)
    popen_streaming(cmd, prompt) do |line|
      block.call(line) if block_given?
    end
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found"
  end

  # Send a message to an existing session and stream the response line by line.
  # Yields each raw JSON line from the subprocess.
  # Returns { session_id: String, response: String }
  def send_message_streaming(session_id:, message:, &block)
    cmd = build_command(session_id: session_id, streaming: true)
    full_response = ""
    current_session_id = session_id

    popen_streaming(cmd, message) do |line|
      block.call(line) if block_given?
      next if line == :keepalive

      data = JSON.parse(line) rescue nil
      next unless data

      if data["type"] == "result"
        full_response = data["result"] || full_response
        current_session_id = data["session_id"] || current_session_id
      end
    end

    { session_id: current_session_id, response: full_response }
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found"
  end

  class ClaudeCliError < StandardError; end

  # A run that went past its timeout. It has been stopped by the time this is raised.
  class TimeoutError < ClaudeCliError; end

  private

  ALLOWED_TOOLS = %w[
    Read
    Glob
    Grep
    WebFetch
    WebSearch
    mcp__figma__get_figma_data
    mcp__figma__download_figma_images
  ].freeze

  # Code-free tool set for the briefing (Product Owner) chat: no filesystem
  # tools, so it can't read or cite the codebase — it stays a product/UX
  # conversation. Keeps web + Figma so it can still look at a linked reference.
  BRIEFING_TOOLS = %w[
    WebFetch
    WebSearch
    mcp__figma__get_figma_data
    mcp__figma__download_figma_images
  ].freeze

  # The PR reviewer's set: the default tools plus READ-ONLY Jira. A PR usually
  # names its ticket, and the ticket's own record — acceptance criteria, linked
  # issues, what was decided in the discussion — is what separates "this is
  # wrong" from "this is what was asked for". Read only: a reviewer has no
  # business writing to Jira.
  REVIEW_TOOLS = (ALLOWED_TOOLS + %w[
    mcp__jira__jira_get_issue
    mcp__jira__jira_search
  ]).freeze

  # Tools for AI Agents & Alerts: read code, read the web, and act on
  # GitHub + Jira via MCP (list/read PRs, read issues, add/edit Jira comments) so
  # an automation can e.g. scan PRs and post a Jira comment. Read + a NARROW set
  # of writes (issue comments only) — no destructive GitHub/Jira actions
  # (no delete/transition/move/assign).
  #
  # The Jira tool names are those exposed by mcp-atlassian (the server wired in
  # each project's .mcp.json) — specific tools, not generic HTTP verbs.
  #
  # The GitHub names are github/github-mcp-server's (verified against a live
  # tools/list on the server, not guessed): it folded get_pull_request and
  # get_pull_request_files into one pull_request_read tool, so the old names
  # would silently never be granted.
  #
  # jira_get_issue*_development_info is Jira's development panel — which
  # branch/PR/commit is linked to a ticket. Without it, connecting a ticket to
  # its PR required that PR to already be in the board snapshot.
  #
  # mcp__lit__* is our own narrow server (lib/mcp/lit_server.rb), so the i18n
  # automation can read what Lit serves and post its proposals without being
  # handed Bash.
  #
  # NOTE: %w[] takes no comments — a "#" line inside the literal below becomes a
  # list of bogus tool names, one per word. Keep prose up here.
  AUTOMATION_TOOLS = %w[
    Read
    Glob
    Grep
    WebFetch
    WebSearch
    mcp__github__list_pull_requests
    mcp__github__search_pull_requests
    mcp__github__search_issues
    mcp__github__pull_request_read
    mcp__github__get_file_contents
    mcp__github__search_code
    mcp__github__list_commits
    mcp__github__get_commit
    mcp__jira__jira_search
    mcp__jira__jira_get_issue
    mcp__jira__jira_get_project_issues
    mcp__jira__jira_get_transitions
    mcp__jira__jira_get_issue_development_info
    mcp__jira__jira_get_issues_development_info
    mcp__jira__jira_add_comment
    mcp__jira__jira_edit_comment
    mcp__lit__lookup_translations
    mcp__lit__post_suggestions
    mcp__lit__refresh_keys
  ].freeze

  # new_session_id names a session that does not exist yet (--session-id); it is
  # for a first run, where session_id (--resume) would name an existing one.
  def build_command(session_id: nil, streaming: false, new_session_id: nil)
    cmd = [CLAUDE_CMD, "-p"]
    # --bare is what guarantees the server's own Claude login is never used for a
    # run that was given a key: it makes the CLI read only ANTHROPIC_API_KEY, never
    # OAuth or the keychain.
    cmd << "--bare" if @api_key.present?
    cmd << "--restricted" if @restricted

    if streaming
      cmd += ["--output-format", "stream-json", "--verbose"]
    else
      cmd += ["--output-format", "json"]
    end

    cmd += ["--resume", session_id] if session_id
    cmd.push("--session-id", new_session_id) if new_session_id.present?
    cmd += ["--model", @model] if @model.present?
    cmd += ["--mcp-config", @mcp_config, "--strict-mcp-config"] if @mcp_config.present?
    cmd.push("--append-system-prompt-file", @append_system_prompt_file) if @append_system_prompt_file.present?
    @add_dirs.each { |dir| cmd.push("--add-dir", dir) }
    # IO.popen takes strings only, and the budget may have been given as a number.
    cmd.push("--max-budget-usd", @max_budget_usd.to_s) unless @max_budget_usd.nil?
    cmd.push("--tools", @tools.join(",")) unless @tools.nil?
    # Pre-approve the tools we want the chat assistant to use without
    # prompting. -p (non-interactive) refuses any tool not on this list.
    @allowed_tools.each { |t| cmd += ["--allowedTools", t] }
    cmd
  end

  # IO.popen arguments for a run: the subprocess environment first when there is
  # an API key, then the command. Without a key nothing is passed, so the
  # environment is inherited exactly as before. With one, the key is the run's
  # only credential: --bare reads nothing else, and the variables that carry the
  # server's own Claude login are unset in the child all the same (a nil value
  # unsets one). The rest of the environment is kept, PATH and HOME with it.
  def popen_args(cmd)
    return [ cmd ] unless @api_key.present?

    [ { "ANTHROPIC_API_KEY" => @api_key, "CLAUDE_CODE_OAUTH_TOKEN" => nil, "ANTHROPIC_AUTH_TOKEN" => nil }, cmd ]
  end

  # One non-streaming run: the prompt goes in, the CLI's JSON answer comes out.
  # is_error is the CLI's word that the run ended in an error rather than an
  # answer: an API error (an overload past its own retries, say) comes back as
  # a result whose text is the error, and the cost cap as one with no text.
  def run_session(cmd, prompt)
    output = run_claude(cmd, prompt)
    data = JSON.parse(output)

    {
      session_id: data["session_id"],
      response: data["result"] || "",
      is_error: data["is_error"] == true
    }
  rescue JSON::ParserError => e
    Rails.logger.error("[ClaudeCliService] Failed to parse response: #{e.message}")
    raise ClaudeCliError, "Failed to parse Claude response"
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
  end

  # One streamed run, its events handed to the block as they come. Returns
  # { session_id:, response:, is_error:, subtype:, final_text:, final_tool_use: }:
  # subtype is the result's ("success", or what the run ended in, such as
  # "error_max_budget_usd"); final_text is what Claude's last message said, and
  # final_tool_use whether that message went on to use a tool. The cost cap ends
  # a run with no result text, though Claude may have finished its answer by
  # then. A subagent's messages are not Claude's own. A run with no result (a
  # session the CLI cannot resume, an id it will not start) raises
  # ClaudeCliError, as a non-streaming one does.
  def stream_session(cmd, prompt)
    result = nil
    last = nil
    said = Hash.new { |texts, id| texts[id] = +"" }
    used_tool = {}
    stream_claude(cmd, prompt) do |event|
      if event.is_a?(Hash) && event["type"] == "assistant" && !event["parent_tool_use_id"]
        last = event.dig("message", "id")
        Array(event.dig("message", "content")).grep(Hash).each do |block|
          said[last] << block["text"].to_s if block["type"] == "text"
          used_tool[last] = true if block["type"] == "tool_use"
        end
      elsif event.is_a?(Hash) && event["type"] == "result"
        result = event
      end
      yield event
    end
    raise ClaudeCliError, "Claude CLI ended without an answer" unless result

    { session_id: result["session_id"], response: result["result"].to_s, is_error: result["is_error"] == true,
      subtype: result["subtype"], final_text: (last ? said[last] : ""), final_tool_use: used_tool[last] == true }
  end

  # Runs the CLI with the prompt on stdin, and yields each line it prints that is
  # a JSON object, parsed (anything else is skipped), and :tick every `tick`
  # seconds while it prints nothing, so the caller can look up from waiting. The
  # timeout is a deadline this loop keeps, never Timeout around the caller's
  # block, which is then never cut off halfway; handing over the prompt is timed
  # too. Past the deadline, or when the block raises, the CLI is stopped (see
  # stop_child) before the error goes up: IO.popen would otherwise wait for it to
  # finish on its own.
  def stream_claude(cmd, message, tick: TICK_SECONDS, &block)
    IO.popen(*popen_args(cmd), "r+", chdir: @codebase_path) do |io|
      deadline = @timeout && monotonic + @timeout
      begin
        @timeout ? Timeout.timeout(@timeout) { hand_over(io, message) } : hand_over(io, message)
        read_events(io, deadline, tick, &block)
      rescue Timeout::Error
        stop_child(io.pid)
        raise TimeoutError, "Claude CLI did not finish within #{@timeout} seconds and was stopped"
      rescue StandardError
        stop_child(io.pid)
        raise
      end
    end
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
  end

  # A CLI that fails at once (a session it cannot resume) may quit before it
  # reads a long prompt. That run has no answer, which the caller can act on
  # (a turn starts a new session); a broken pipe would hide it.
  def hand_over(io, message)
    io.write(message)
    io.close_write
  rescue Errno::EPIPE
    nil
  end

  # The lines are put together as bytes and read as UTF-8 once whole, so a
  # character split between two reads stays one.
  def read_events(io, deadline, tick)
    buffer = String.new(encoding: Encoding::BINARY)
    loop do
      wait = tick
      if deadline
        left = deadline - monotonic
        raise Timeout::Error if left <= 0

        wait = [ wait, left ].min
      end
      unless IO.select([ io ], nil, nil, wait)
        yield :tick
        next
      end

      chunk = io.read_nonblock(65_536, exception: false)
      next if chunk == :wait_readable
      break if chunk.nil?

      buffer << chunk
      while (newline = buffer.index("\n"))
        event = parse_event(buffer.slice!(0..newline))
        yield event if event
      end
    end
    event = parse_event(buffer)
    yield event if event
  end

  def parse_event(line)
    event = JSON.parse(line.dup.force_encoding(Encoding::UTF_8).strip)
    event if event.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Runs the CLI to the end and returns what it printed. With a timeout, a run that
  # is still going when the time is up (handing over the prompt included) is stopped
  # (see stop_child) and TimeoutError is raised. Without one nothing is timed.
  def run_claude(cmd, message)
    IO.popen(*popen_args(cmd), "r+", chdir: @codebase_path) do |io|
      next exchange(io, message) unless @timeout

      begin
        Timeout.timeout(@timeout) { exchange(io, message) }
      rescue Timeout::Error
        stop_child(io.pid)
        raise TimeoutError, "Claude CLI did not finish within #{@timeout} seconds and was stopped"
      end
    end
  end

  # The prompt goes in on stdin; everything the CLI prints comes back.
  def exchange(io, message)
    io.write(message)
    io.close_write
    io.read
  end

  # Stops the CLI of a run that is out of time: TERM first, so it can clean up after
  # itself, then KILL if it is still there once the grace period is over. It is
  # waited for either way, so no zombie is left behind, and IO.popen finds nothing
  # to wait for when its block ends. The signals go to the CLI process only.
  def stop_child(pid, grace: KILL_GRACE_SECONDS)
    Process.kill("TERM", pid)
    begin
      Timeout.timeout(grace) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already gone and collected: there is nothing left to stop
  end

  def popen_streaming(cmd, message, keepalive_interval: 10, &block)
    IO.popen(*popen_args(cmd), "r+", chdir: @codebase_path) do |io|
      io.write(message)
      io.close_write

      buffer = +""
      loop do
        ready = IO.select([io], nil, nil, keepalive_interval)
        if ready.nil?
          # Idle — let the caller send a keepalive
          block.call(:keepalive)
          next
        end

        chunk = begin
          io.read_nonblock(8192)
        rescue IO::WaitReadable
          next
        rescue EOFError
          nil
        end
        break if chunk.nil?

        buffer << chunk
        while (newline_idx = buffer.index("\n"))
          line = buffer.slice!(0..newline_idx).chomp
          block.call(line) if line.length > 0
        end
      end

      # Flush trailing partial line, if any
      block.call(buffer.strip) if buffer.strip.length > 0
    end
  end
end
