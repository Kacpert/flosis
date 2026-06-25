# Chat session that acts as a skeptical Product Owner: it gathers a brief and
# challenges business requirements (only when it makes sense), focusing on user
# value and the best option given the existing app. Shares all SSE/persistence
# plumbing with the other chats via ChatStreaming; differs only in the prompt
# and how results are extracted. Result blocks are <brief>…</brief>, saved as a
# versioned Brief (status "draft").
class BriefChatSessionsController < ApplicationController
  include WorkspaceScoped
  include ChatStreaming

  CHAT_PURPOSE = "brief".freeze
  BRIEF_BLOCK = /<brief>(.*?)<\/brief>/m

  before_action :require_admin!
  before_action :require_workshop!
  before_action :set_task

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end

  def extract_and_save_results(text)
    text.to_s.scan(BRIEF_BLOCK).each do |(body)|
      content = body.to_s.strip
      next if content.blank?
      @task.briefs.create!(
        workspace: current_workspace,
        chat_session: @chat_session,
        version: Brief.next_version_for(@task),
        content: content,
        status: "draft"
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[BriefChat] Brief extraction failed: #{e.message}")
  end

  def build_initial_prompt
    project = @task.project
    context = project.context_info.presence || "(no project context provided)"
    features = project.features_summary.presence || "(no features summary available yet)"
    ticket_section = if @task.external_reference.present?
      "Existing Jira ticket #{@task.external_reference}: #{ticket_title}\n\nDescription:\n#{@task.description.presence || '(none)'}"
    else
      "New idea (not yet in Jira): #{@task.name}\n\n#{@task.description.presence || '(no detail provided yet)'}"
    end
    comments_section = build_comments_section(@task)
    attachments_section = build_attachments_section(@task)

    <<~PROMPT
      # Role

      You are an experienced, skeptical Product Owner. Your job is to turn an idea
      into a sharp, concise BRIEF. You care about USER VALUE and shipping the right
      thing, not gold-plating. The codebase in your working directory is the app
      this project belongs to.

      # Project context (set by the team — read this first)

      #{context}

      # Current features & architecture (auto-summarised from the codebase)

      #{features}

      # The idea to brief

      #{ticket_section}
      #{comments_section}#{attachments_section}

      # How you must operate

      1. Investigate the codebase quietly (read CLAUDE.md, list app/, read the few
         most relevant files) so your suggestions fit what already exists. Don't
         narrate this.
      2. Act like a PO in conversation: ask focused questions to pin down the real
         user value and scope. Propose the option you think is best given the
         existing app, and what could make it genuinely better for users.
      3. CHALLENGE the business logic ONLY when it makes sense — when a requirement
         is unclear, conflicts with the existing app, adds little value, or a
         simpler/stronger option exists. Do NOT challenge for the sake of it; if the
         idea is sound, say so and move on.
      4. Keep the conversation tight. When you have enough, produce the brief.

      # The brief

      When ready, output exactly ONE `<brief>` block. The brief captures the WHOLE
      concept and describes the feature, but is CONCISE — no padding, no restating
      obvious context, no implementation detail. Aim for something a developer and a
      stakeholder can both read in under a minute.

      <brief>
      (The concise brief: the problem/value, who it's for, what we'll build, and the
      acceptance at a high level.)
      </brief>

      Each new `<brief>` block becomes a new saved version; earlier versions stay
      available. Revise into a new block when the user asks for changes.

      # Start now

      Investigate quietly, then open the conversation with your first PO questions
      (or, if the idea is already clear, a short take plus a first `<brief>` draft).
    PROMPT
  end
end
