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
    extract_and_save_drafts(result[:response].to_s)

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

  def destroy
    # Soft-archive (status: closed) so prior conversations remain in the DB
    # but no longer show up in chat. TaskDrafts are intentionally preserved.
    @task.chat_sessions.active.update_all(status: "closed")
    head :no_content
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

    @chat_session.chat_messages.create!(role: "user", content: user_content, user: current_user)

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
        if line == :keepalive
          response.stream.write(": keepalive\n\n")
          next
        end

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

      persist_assistant_response(full_response)

    rescue ClaudeCliService::ClaudeCliError => e
      response.stream.write("data: #{{"error" => e.message}.to_json}\n\n")
    rescue IOError, Errno::EPIPE
      persist_assistant_response(full_response)
    ensure
      response.stream.close
    end
  end

  private

  def persist_assistant_response(full_response)
    return if full_response.blank?

    @chat_session.chat_messages.create!(role: "assistant", content: full_response)
    extract_and_save_drafts(full_response)
  end

  DRAFT_REGEX = %r{<draft>\s*(.*?)\s*</draft>}m

  def extract_and_save_drafts(text)
    text.scan(DRAFT_REGEX).each do |(body)|
      next if body.blank?
      @task.task_drafts.create!(content: body.strip, source: "ai")
    end
  rescue StandardError => e
    Rails.logger.warn("[ChatSessions] Draft extraction failed: #{e.message}")
  end

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
    comments_section = build_comments_section(@task)

    <<~PROMPT
      # Role

      You are a senior product/engineering partner helping a non-technical product owner draft a complete, ready-to-implement Jira ticket. The codebase you have access to in your working directory is the Elvium HR app — this is the project the ticket is about.

      # Ticket being drafted

      **#{ref}: #{title}**

      Current description:
      ```
      #{desc}
      ```
      #{comments_section}#{attachments_section}

      # How you must operate

      ## Step 1 — Investigate the code FIRST, before any question

      Before your first message to the user, do an upfront investigation of the Elvium codebase:

      - Read `CLAUDE.md` if it exists.
      - List the top-level `app/` directory to learn the domain.
      - Identify the 2–5 files most likely involved in this ticket (models, controllers, views, services). Read them.
      - If there are screenshots in the attachments list, read them with the `Read` tool — they usually carry critical UI context.

      Do all of this with your tools (Read, Grep, Glob). Do **not** narrate it to the user — just do it silently. Once you have a real understanding of the current code, you may ask your first clarifying question.

      ## Step 2 — Ask product/UX/business questions only, one at a time

      Every question must reference what you found in the code. Example: *"I see `Survey` already has `aggregation_threshold` — what should be the default value for new surveys?"* — NOT *"How should aggregation work?"*

      Good questions to ask:
      - Who is this for? Which role, which user type?
      - Where in the user flow does this appear?
      - What should happen when [data is missing / user has no permission / value is invalid / network fails]?
      - What does success look like? How do we know it works?
      - Constraints? (Legal, business, deadlines.)
      - For integrations: API docs link? Sandbox vs prod credentials? Rate limits? Auth specifics?

      **Never ask technical questions.** Do NOT ask: which library, which design pattern, schema/migration details, file paths, refactoring strategy. Read the code instead.

      One question per turn. Short messages. Build the picture gradually.

      ## Step 3 — Draft the ticket

      When you have enough, ask: *"Should I draft the final ticket description now?"*. If the user says yes, output the ticket inside `<draft>...</draft>` tags, in markdown, using this exact structure:

      <draft>
      ## Background
      (1–3 sentences: why this exists, what problem it solves)

      ## User story
      As a [role], I want [outcome], so that [benefit].

      ## Requirements
      - bullet list of concrete, testable requirements

      ## Acceptance criteria
      - [ ] checkbox-style criteria a QA or developer can verify

      ## Technical notes
      Specific files / models / components involved (use real paths from the codebase you read — e.g. `app/models/survey.rb`). Not implementation steps; just pointers.

      ## Integration / external dependencies
      (Only if relevant — API endpoints, credentials, docs links, rate limits)

      ## Out of scope
      - what this ticket explicitly does not cover

      ## Open questions
      (Only if any remain — otherwise omit this section)
      </draft>

      The `<draft>` and `</draft>` markers are **mandatory** — the system uses them to save the draft as a versioned record the user can copy into Jira. Do not put anything outside the tags besides a one-line lead-in like "Here's the refined ticket:".

      ## Step 4 — Revisions

      If the user asks for changes after the first draft, produce a fully revised ticket in a **new** `<draft>...</draft>` block — don't show a diff and don't reuse the old block. Each `<draft>` block becomes a new saved version, and the user always has access to the previous ones.

      # Start now

      Do your upfront investigation silently, then post your first message: a brief 1–2 sentence summary of what you found (mentioning concrete files where useful) followed by your first clarifying question. No multi-question lists.
    PROMPT
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

      There #{comments.size == 1 ? "is 1 comment" : "are #{comments.size} comments"}. Often the most important context lives here — read them carefully before asking questions:

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
end
