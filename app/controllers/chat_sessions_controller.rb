class ChatSessionsController < ApplicationController
  include WorkspaceScoped
  include ActionController::Live  # Required for SSE streaming in message action

  before_action :require_employee!
  before_action :set_task

  def create
    @chat_session = ChatSession.find_active_for(@task, current_user)

    if @chat_session
      render json: session_json(@chat_session)
      return
    end

    service = ClaudeCliService.new
    prompt = build_initial_prompt

    begin
      result = service.start_session(prompt: prompt)
    rescue ClaudeCliService::ClaudeCliError => e
      render json: { error: e.message }, status: :service_unavailable
      return
    end

    unless result[:session_id].present?
      render json: { error: "Claude did not return a session ID" }, status: :service_unavailable
      return
    end

    @chat_session = ChatSession.create!(
      task: @task,
      workspace: current_workspace,
      user: current_user,
      claude_session_id: result[:session_id],
      codebase_path: ClaudeCliService::DEFAULT_CODEBASE_PATH
    )

    @chat_session.chat_messages.create!(
      role: "assistant",
      content: result[:response]
    )

    render json: session_json(@chat_session)
  end

  def show
    @chat_session = ChatSession.find_active_for(@task, current_user)

    if @chat_session
      render json: session_json(@chat_session)
    else
      render json: { error: "No active chat session" }, status: :not_found
    end
  end

  def message
    @chat_session = ChatSession.find_active_for(@task, current_user)

    unless @chat_session
      render json: { error: "No active chat session" }, status: :not_found
      return
    end

    user_content = params[:content].to_s.strip
    if user_content.blank?
      render json: { error: "Message content required" }, status: :unprocessable_entity
      return
    end

    @chat_session.chat_messages.create!(role: "user", content: user_content)

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    service = ClaudeCliService.new(codebase_path: @chat_session.codebase_path)
    full_response = ""

    begin
      result = service.send_message_streaming(
        session_id: @chat_session.claude_session_id,
        message: user_content
      ) do |line|
        data = JSON.parse(line) rescue nil
        next unless data

        if data["type"] == "assistant"
          text = data.dig("message", "content")&.filter_map { |c| c["text"] }&.join("")
          if text.present?
            full_response += text
            response.stream.write("data: #{text.to_json}\n\n")
          end
        elsif data["type"] == "result"
          full_response = data["result"] if data["result"].present?
          response.stream.write("data: #{{"done" => true}.to_json}\n\n")
        end
      end

      if result[:session_id] != @chat_session.claude_session_id
        @chat_session.update!(claude_session_id: result[:session_id])
      end

      @chat_session.chat_messages.create!(role: "assistant", content: full_response) if full_response.present?

    rescue ClaudeCliService::ClaudeCliError => e
      response.stream.write("data: #{{"error" => e.message}.to_json}\n\n")
    rescue IOError, Errno::EPIPE
      @chat_session.chat_messages.create!(role: "assistant", content: full_response) if full_response.present?
    ensure
      response.stream.close
    end
  end

  private

  def set_task
    @task = Task.joins(:project)
               .where(projects: { workspace_id: current_workspace.id })
               .find(params[:jira_task_id])
  end

  def build_initial_prompt
    desc = @task.description.presence || "(no description provided)"
    title = @task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, "")
    ref = @task.external_reference
    attachments_section = build_attachments_section(@task)

    <<~PROMPT
      # Role

      You are a senior product/engineering partner helping a non-technical product owner draft a complete, ready-to-implement Jira ticket. The codebase you have access to in your working directory is the Elvium HR app — this is the project the ticket is about.

      # Ticket being drafted

      **#{ref}: #{title}**

      Current description:
      ```
      #{desc}
      ```
      #{attachments_section}

      # How you must operate

      1. **Read the existing description first.** Identify what's already known and what's missing.
      2. **Investigate the codebase yourself** to answer technical questions. Read files, grep for relevant models/views/controllers, follow references. Never ask the user technical questions you can answer by reading code — which gem to use, which file to put something in, what the schema looks like, what an existing method does, etc.
      3. **Ask the user ONE question at a time.** Ask only product/UX/business questions that *cannot* be answered from code. Examples of good questions:
         - Who is this for? (which role, which user type)
         - Where in the user flow does this appear?
         - What should happen when [data is missing / user has no permission / value is invalid / network fails]?
         - What does success look like? How do we know it works?
         - Are there constraints we should respect (legal, business rules, deadlines)?
         - For integrations: where is the API documentation? What credentials should we use (sandbox vs prod)? Are there rate limits or auth specifics?
      4. **Never ask technical questions.** Do NOT ask: which library, which design pattern, schema/migration details, file paths, refactoring strategy. Figure these out by reading the code.
      5. **Don't dump everything at once.** Short messages. One question per turn. Build the picture gradually.
      6. **When you have enough to specify the ticket**, ask the user "Should I draft the final ticket description now?" If they say yes, output the final ticket in **markdown** using exactly this structure:

         ```
         ## Background
         (1–3 sentences: why this exists, what problem it solves)

         ## User story
         As a [role], I want [outcome], so that [benefit].

         ## Requirements
         - bullet list of concrete requirements
         - each one specific and testable

         ## Acceptance criteria
         - [ ] checkbox-style criteria a QA or developer can verify

         ## Technical notes
         (Files/models/components involved — what you found in the codebase. Not implementation steps, just pointers.)

         ## Integration / external dependencies
         (Only if relevant — API endpoints, credentials, docs links, rate limits)

         ## Out of scope
         - what this ticket explicitly does not cover

         ## Open questions
         (Only if any remain — otherwise omit this section)
         ```

      # Start now

      Read the existing ticket description above. Briefly (1–2 sentences) acknowledge what you understand so far, then ask your **first** clarifying question. Do not list multiple questions.
    PROMPT
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

      The ticket has #{files.size} attached file(s). Use the `Read` tool on these paths to view them — screenshots usually carry the most context, so read them before asking questions about the UI:

      #{listing}
    SECTION
  end

  def session_json(chat_session)
    {
      chat_session: {
        id: chat_session.id,
        claude_session_id: chat_session.claude_session_id,
        status: chat_session.status,
        messages: chat_session.chat_messages.ordered.map do |msg|
          { id: msg.id, role: msg.role, content: msg.content, created_at: msg.created_at }
        end
      }
    }
  end
end
