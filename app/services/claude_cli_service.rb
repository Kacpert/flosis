class ClaudeCliService
  CLAUDE_CMD = "claude".freeze
  DEFAULT_CODEBASE_PATH = File.expand_path("~/work/elvium").freeze

  def initialize(codebase_path: nil, allowed_tools: nil, model: nil, mcp_config: nil)
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
  end

  # Start a new Claude session with an initial prompt.
  # Returns { session_id: String, response: String }
  def start_session(prompt:)
    cmd = build_command(streaming: false)
    output = run_claude(cmd, prompt)
    data = JSON.parse(output)

    {
      session_id: data["session_id"],
      response: data["result"] || ""
    }
  rescue JSON::ParserError => e
    Rails.logger.error("[ClaudeCliService] Failed to parse response: #{e.message}")
    raise ClaudeCliError, "Failed to parse Claude response"
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
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
  AUTOMATION_TOOLS = %w[
    Read
    Glob
    Grep
    WebFetch
    WebSearch
    mcp__github__list_pull_requests
    mcp__github__search_pull_requests
    mcp__github__pull_request_read
    mcp__github__get_file_contents
    mcp__github__search_code
    mcp__github__list_commits
    mcp__github__get_commit
    mcp__jira__jira_search
    mcp__jira__jira_get_issue
    mcp__jira__jira_get_project_issues
    mcp__jira__jira_get_transitions
    mcp__jira__jira_add_comment
    mcp__jira__jira_edit_comment
  ].freeze

  def build_command(session_id: nil, streaming: false)
    cmd = [CLAUDE_CMD, "-p"]

    if streaming
      cmd += ["--output-format", "stream-json", "--verbose"]
    else
      cmd += ["--output-format", "json"]
    end

    cmd += ["--resume", session_id] if session_id
    cmd += ["--model", @model] if @model.present?
    cmd += ["--mcp-config", @mcp_config, "--strict-mcp-config"] if @mcp_config.present?
    # Pre-approve the tools we want the chat assistant to use without
    # prompting. -p (non-interactive) refuses any tool not on this list.
    @allowed_tools.each { |t| cmd += ["--allowedTools", t] }
    cmd
  end

  def run_claude(cmd, message)
    IO.popen(cmd, "r+", chdir: @codebase_path) do |io|
      io.write(message)
      io.close_write
      io.read
    end
  end

  def popen_streaming(cmd, message, keepalive_interval: 10, &block)
    IO.popen(cmd, "r+", chdir: @codebase_path) do |io|
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
