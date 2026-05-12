class ClaudeCliService
  CLAUDE_CMD = "claude".freeze
  DEFAULT_CODEBASE_PATH = File.expand_path("~/work/elvium").freeze

  def initialize(codebase_path: nil)
    @codebase_path = codebase_path || ENV.fetch("CHAT_CODEBASE_PATH", DEFAULT_CODEBASE_PATH)
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

  # Send a message to an existing session and stream the response line by line.
  # Yields each raw JSON line from the subprocess.
  # Returns { session_id: String, response: String }
  def send_message_streaming(session_id:, message:, &block)
    cmd = build_command(session_id: session_id, streaming: true)
    full_response = ""
    current_session_id = session_id

    popen_streaming(cmd, message) do |line|
      block.call(line) if block_given?

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

  def build_command(session_id: nil, streaming: false)
    cmd = [CLAUDE_CMD, "-p"]

    if streaming
      cmd += ["--output-format", "stream-json", "--verbose"]
    else
      cmd += ["--output-format", "json"]
    end

    cmd += ["--resume", session_id] if session_id
    cmd
  end

  def run_claude(cmd, message)
    IO.popen(cmd, "r+", chdir: @codebase_path) do |io|
      io.write(message)
      io.close_write
      io.read
    end
  end

  def popen_streaming(cmd, message, &block)
    IO.popen(cmd, "r+", chdir: @codebase_path) do |io|
      io.write(message)
      io.close_write
      io.each_line { |line| block.call(line.strip) if line.strip.present? }
    end
  end
end
