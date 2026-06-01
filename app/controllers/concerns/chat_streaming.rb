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
  end

  def chat_purpose
    self.class::CHAT_PURPOSE
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

    service = ClaudeCliService.new
    full_response = ""
    @stream_session_id = nil

    begin
      service.send_initial_streaming(prompt: build_initial_prompt) do |line|
        handle_stream_line(line) { |chunk| full_response += chunk }
      end

      new_session_id = @stream_session_id
      final_text = @authoritative_result.presence || full_response
      if new_session_id.present? && final_text.present?
        @chat_session = ChatSession.create!(
          task: @task,
          workspace: current_workspace,
          user: current_user,
          purpose: chat_purpose,
          claude_session_id: new_session_id,
          codebase_path: ClaudeCliService::DEFAULT_CODEBASE_PATH
        )
        @chat_session.chat_messages.create!(role: "assistant", content: final_text)
        extract_and_save_results(final_text)
        write_sse("done" => true, "session_id" => @chat_session.id)
      else
        write_sse("error" => "Claude did not return a session ID")
      end
    rescue ClaudeCliService::ClaudeCliError => e
      write_sse("error" => e.message)
    rescue IOError, Errno::EPIPE
      # client disconnected
    ensure
      response.stream.close
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

    service = ClaudeCliService.new(codebase_path: @chat_session.codebase_path)
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
      write_sse("error" => e.message)
    rescue IOError, Errno::EPIPE
      persist_assistant_response(full_response)
    ensure
      response.stream.close
    end
  end

  private

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
      text = data.dig("message", "content")&.filter_map { |c| c["text"] }&.join("")
      if text.present?
        yield text if block_given?
        response.stream.write("data: #{text.to_json}\n\n")
      end
    when "result"
      # The final "result" event carries the authoritative full text, used for
      # block extraction so it runs against the complete, untruncated response.
      @authoritative_result = data["result"] if data["result"].present?
      @stream_session_id = data["session_id"] if data["session_id"].present?
      write_sse("done" => true) if final_done
    when "system"
      @stream_session_id ||= data["session_id"]
    end
  end

  def persist_assistant_response(full_response)
    text = @authoritative_result.presence || full_response
    return if text.blank?

    @chat_session.chat_messages.create!(role: "assistant", content: text)
    extract_and_save_results(text)
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
            created_at: msg.created_at,
            author: msg.user&.name
          }
        end
      }
    }
  end

  def set_task
    @task = Task.joins(:project)
               .where(projects: { workspace_id: current_workspace.id })
               .find(params[:jira_task_id])
  end
end
