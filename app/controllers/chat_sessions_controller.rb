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
    desc = @task.description.presence || "No description"

    "You are helping with Jira ticket #{@task.external_reference}: " \
    "#{@task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, '')}.\n\n" \
    "Here is the ticket description:\n\n#{desc}\n\n" \
    "You have access to the codebase. " \
    "Acknowledge briefly what the ticket is about and ask what the user would like to work on."
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
