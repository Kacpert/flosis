# Shared machinery for task-bound Claude chat sessions that stream over SSE.
#
# Two controllers consume this: ChatSessionsController (purpose: "refine",
# drafts a ticket description) and BreakdownChatSessionsController
# (purpose: "breakdown", estimates + splits a task). They differ only in the
# prompt they build and how they extract/persist result blocks; everything
# else — session lookup, SSE plumbing, persistence of chat messages — lives
# here.
#
# A consuming controller must:
#   * set CHAT_PURPOSE (or override #chat_purpose)
#   * implement #build_initial_prompt
#   * implement #extract_and_save_results(text) — pull its result blocks
#     (<draft> / <breakdown>) out of the assistant text and persist them
#
# It also gets the shared context helpers (#build_attachments_section,
# #build_comments_section, #ticket_title) for free.
module ChatStreaming
  extend ActiveSupport::Concern

  included do
    include ActionController::Live # SSE
    rescue_from ActiveRecord::RecordNotFound, with: :jira_record_not_found
  end

  def chat_purpose
    self.class::CHAT_PURPOSE
  end

  # Per-chat override of the CLI's pre-approved tool list. nil = use the service
  # default (full read/search set). The briefing chat overrides this with a
  # code-free set so it can't read the codebase.
  def chat_allowed_tools
    nil
  end

  # POST — return the existing active session, or start a new one and stream
  # the initial investigation + first answer back as SSE.
  def create
    @chat_session = ChatSession.find_active_for(@task, current_user, purpose: chat_purpose)

    if @chat_session
      render json: session_json(@chat_session)
      return
    end

    write_sse_headers

    service = ClaudeCliService.new(allowed_tools: chat_allowed_tools)
    full_response = ""
    @stream_session_id = nil

    client_gone = false
    cli_error = nil
    begin
      begin
        service.send_initial_streaming(prompt: build_initial_prompt) do |line|
          handle_stream_line(line) { |chunk| full_response += chunk }
        end
      rescue ClaudeCliService::ClaudeCliError => e
        cli_error = e.message
      rescue ActionController::Live::ClientDisconnected, IOError, Errno::EPIPE
        # The client navigated away / a duplicate request superseded this one. The
        # Claude subprocess still finished its work (60-80s), so DON'T throw it
        # away — fall through and persist the session below so the next page load
        # resumes it instead of paying that cost again.
        client_gone = true
      end

      new_session_id = @stream_session_id
      final_text = @authoritative_result.presence || full_response
      if new_session_id.present? && final_text.present?
        @chat_session = persist_initial_session!(new_session_id, final_text, full_response)
        # Send the clean authoritative final text so the bubble collapses from the
        # live tool-use progress to just the answer (same as the #message path).
        write_sse_safe("done" => true, "session_id" => @chat_session.id, "final" => @authoritative_result.presence) unless client_gone
      elsif cli_error
        write_sse_safe("error" => cli_error) unless client_gone
      elsif !client_gone
        write_sse_safe("error" => "Claude did not return a session ID")
      end
    ensure
      close_stream_safe
    end
  end

  def show
    @chat_session = ChatSession.find_active_for(@task, current_user, purpose: chat_purpose)

    if @chat_session
      render json: session_json(@chat_session)
    else
      render json: { error: "No active chat session" }, status: :not_found
    end
  end

  def destroy
    # Soft-archive so prior conversations remain in the DB but no longer show
    # in chat. TaskDrafts (refined descriptions / breakdowns) are preserved.
    @task.chat_sessions.active.where(purpose: chat_purpose).update_all(status: "closed")
    head :no_content
  end

  def message
    @chat_session = ChatSession.find_active_for(@task, current_user, purpose: chat_purpose)

    unless @chat_session
      render json: { error: "No active chat session" }, status: :not_found
      return
    end

    user_content = params[:content].to_s.strip
    if user_content.blank?
      render json: { error: "Message content required" }, status: :unprocessable_entity
      return
    end

    @chat_session.chat_messages.create!(role: "user", content: user_content, user: current_user)

    write_sse_headers

    service = ClaudeCliService.new(codebase_path: @chat_session.codebase_path, allowed_tools: chat_allowed_tools)
    full_response = ""

    begin
      result = service.send_message_streaming(
        session_id: @chat_session.claude_session_id,
        message: user_content
      ) do |line|
        handle_stream_line(line, final_done: true) { |chunk| full_response += chunk }
      end

      if result[:session_id] != @chat_session.claude_session_id
        @chat_session.update!(claude_session_id: result[:session_id])
      end

      persist_assistant_response(full_response)
    rescue ClaudeCliService::ClaudeCliError => e
      write_sse_safe("error" => e.message)
    rescue ActionController::Live::ClientDisconnected, IOError, Errno::EPIPE
      # Client gone mid-answer — still persist what we got so it isn't lost.
      persist_assistant_response(full_response)
    ensure
      close_stream_safe
    end
  end

  private

  # SSE writes/close can themselves raise ClientDisconnected once the client is
  # gone; these swallow that so a disconnect never turns into a 500.
  def write_sse_safe(payload)
    write_sse(payload)
  rescue ActionController::Live::ClientDisconnected, IOError, Errno::EPIPE
    nil
  end

  def close_stream_safe
    response.stream.close
  rescue ActionController::Live::ClientDisconnected, IOError, Errno::EPIPE
    nil
  end

  # Parse one raw line from the Claude subprocess and stream the relevant part
  # to the client. Yields any assistant text chunk to the caller so it can
  # accumulate the full response. Tracks the session id in @stream_session_id
  # ("result" is authoritative and overwrites; "system" only fills a blank)
  # and the authoritative final text in @authoritative_result. When final_done
  # is true, a "result" event also writes the SSE done marker (used by
  # #message; #create writes done itself after creating the session).
  def handle_stream_line(line, final_done: false)
    if line == :keepalive
      response.stream.write(": keepalive\n\n")
      return
    end

    data = JSON.parse(line) rescue nil
    return unless data

    case data["type"]
    when "assistant"
      # An assistant turn's content is an array of blocks: "text" (narration) and
      # "tool_use" (a Read/Grep/etc call). We must surface BOTH. If we only kept
      # text, a turn that goes straight to a tool call — common when the AI
      # investigates the codebase — streamed nothing, so the user stared at
      # frozen "thinking…" dots and, because nothing streamed, got no "Show
      # thinking" toggle afterward. Render tool calls as a short narration line
      # ("_Reading CLAUDE.md…_") so there's always live progress AND saved thinking.
      text = Array(data.dig("message", "content")).filter_map { |c| block_narration(c) }.join("\n")
      if text.present?
        # Each "assistant" event is a distinct turn (e.g. a thought before a tool
        # call). They must not be glued together ("…Rails app.Now let me search…").
        # Separate consecutive turns with a blank line so they render as their own
        # paragraphs, both in the live stream and the accumulated full_response.
        chunk = @streamed_any_assistant ? "\n\n#{text}" : text
        @streamed_any_assistant = true
        yield chunk if block_given?
        response.stream.write("data: #{chunk.to_json}\n\n")
      end
    when "result"
      # The final "result" event carries the authoritative full text (the clean
      # final answer, WITHOUT the intermediate tool-use narration streamed above).
      # Used for block extraction and sent to the client so the bubble collapses
      # from the live progress to just the clean answer.
      @authoritative_result = data["result"] if data["result"].present?
      @stream_session_id = data["session_id"] if data["session_id"].present?
      write_sse({ "done" => true, "final" => @authoritative_result }.compact) if final_done
    when "system"
      @stream_session_id ||= data["session_id"]
    end
  end

  # Turns one assistant content block into a line of streamable narration.
  # "text" blocks pass through verbatim. "tool_use" blocks (Read/Grep/etc.)
  # become a short italic "doing X…" line so the investigation is visible while
  # it happens and is saved behind the "Show thinking" toggle. Unknown block
  # types are ignored.
  def block_narration(block)
    return nil unless block.is_a?(Hash)

    case block["type"]
    when "text"
      t = block["text"].to_s
      t.presence
    when "tool_use"
      tool_narration(block["name"], block["input"])
    end
  end

  # A human-readable one-liner for a tool call. Kept short and product-plain —
  # this is what the user sees under "Show thinking", not a debugger.
  def tool_narration(name, input)
    input = input.is_a?(Hash) ? input : {}
    case name.to_s
    when "Read"
      path = input["file_path"].to_s
      "_Reading #{short_path(path)}…_"
    when "Grep"
      pat = input["pattern"].to_s
      pat.present? ? "_Searching the code for `#{pat}`…_" : "_Searching the code…_"
    when "Glob"
      "_Looking for #{input["pattern"].presence || 'files'}…_"
    when "WebFetch"
      "_Opening #{input["url"].presence || 'a link'}…_"
    when "WebSearch"
      q = input["query"].to_s
      q.present? ? "_Searching the web for “#{q}”…_" : "_Searching the web…_"
    when /\Amcp__figma__/
      "_Looking at the Figma reference…_"
    else
      name.present? ? "_Working (#{name})…_" : nil
    end
  end

  # Trim an absolute path down to something readable in the chat (last 2-3 parts).
  def short_path(path)
    return "a file" if path.blank?
    parts = path.split("/").reject(&:blank?)
    parts.last(3).join("/")
  end

  def persist_initial_session!(session_id, final_text, full_response)
    session = ChatSession.create!(
      task: @task,
      workspace: current_workspace,
      user: current_user,
      purpose: chat_purpose,
      claude_session_id: session_id,
      codebase_path: ClaudeCliService::DEFAULT_CODEBASE_PATH
    )
    session.chat_messages.create!(
      role: "assistant", content: final_text, thinking: thinking_for(full_response, final_text)
    )
    extract_and_save_results(final_text)
    session
  end

  def persist_assistant_response(full_response)
    text = @authoritative_result.presence || full_response
    return if text.blank?

    @chat_session.chat_messages.create!(role: "assistant", content: text, thinking: thinking_for(full_response, text))
    extract_and_save_results(text)
  end

  # The tool-use narration to persist alongside the answer: the streamed text,
  # but only when it actually differs from the clean answer (otherwise there's
  # nothing to "show" and we store nil so no toggle renders).
  def thinking_for(streamed, answer)
    streamed = streamed.to_s.strip
    return nil if streamed.blank?
    return nil if streamed.gsub(/\s+/, " ") == answer.to_s.strip.gsub(/\s+/, " ")
    streamed
  end

  def write_sse_headers
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
  end

  def write_sse(payload)
    response.stream.write("data: #{payload.to_json}\n\n")
  end

  # ---- shared task context helpers -------------------------------------

  def ticket_title
    @task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, "")
  end

  def build_comments_section(task)
    comments = task.jira_comments.ordered
    return "" if comments.empty?

    formatted = comments.map do |c|
      author = c.author_name.presence || c.author_email.presence || "Unknown"
      when_at = c.jira_created_at&.strftime("%Y-%m-%d %H:%M") || ""
      "**#{author}** (#{when_at}):\n#{c.body.to_s.strip}"
    end.join("\n\n---\n\n")

    <<~SECTION

      # Comments on this ticket

      There #{comments.size == 1 ? "is 1 comment" : "are #{comments.size} comments"}. Often the most important context lives here — read them carefully:

      #{formatted}
    SECTION
  end

  def build_attachments_section(task)
    return "" unless task.attachments.attached?

    dir = task.attachments_disk_dir
    return "" if dir.blank?

    files = task.attachments.map do |att|
      File.join(dir, att.filename.to_s.gsub(/[^\w.\- ]/, "_").gsub(/\s+/, "_"))
    end
    return "" if files.empty?

    listing = files.map { |p| "- #{p}" }.join("\n")

    <<~SECTION

      # Attachments on this ticket

      The ticket has #{files.size} attached file(s). Use the `Read` tool on these paths to view them — screenshots usually carry the most context, so read them before deciding anything about the UI:

      #{listing}
    SECTION
  end

  def session_json(chat_session)
    {
      chat_session: {
        id: chat_session.id,
        claude_session_id: chat_session.claude_session_id,
        status: chat_session.status,
        purpose: chat_session.purpose,
        messages: chat_session.chat_messages.includes(:user).ordered.map do |msg|
          {
            id: msg.id,
            role: msg.role,
            content: msg.content,
            thinking: msg.thinking,
            created_at: msg.created_at,
            author: msg.user&.name
          }
        end
      }
    }
  end

  def set_task
    @task = Task.where(project_id: visible_jira_projects.select(:id)).find(params[:jira_task_id])
  end
end
