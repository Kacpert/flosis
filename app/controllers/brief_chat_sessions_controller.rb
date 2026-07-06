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

  before_action { require_product!(:workshop) }
  before_action :require_workshop_member!
  before_action :require_workshop!
  before_action :set_task

  private

  # Briefing is a product/UX conversation — run without filesystem tools so the
  # PO can't read or cite the codebase (see BRIEFING_TOOLS / the prompt's no-code
  # rule). The details & breakdown chats keep the full read/search set.
  def chat_allowed_tools
    ClaudeCliService::BRIEFING_TOOLS
  end

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
      ).make_current!
    end
  rescue StandardError => e
    Rails.logger.warn("[BriefChat] Brief extraction failed: #{e.message}")
  end

  def build_initial_prompt
    project = @task.project
    context = project.context_info.presence || "(no project context provided)"
    # Two additional, admin-maintained inputs layered onto the main brief prompt:
    #   * features_summary — auto-scanned daily (+ manual refresh) plain-language
    #     list of what the app already does, so the PO knows the current product.
    #   * briefing_personas — human-written personas / product perspective.
    features = project.features_summary.presence
    personas = project.briefing_personas.presence
    features_section = features ? "\n\n# What the app already does (auto-maintained; read this so you don't propose things that already exist)\n\n#{features}" : ""
    personas_section = personas ? "\n\n# Who uses this app & our perspective (set by the team)\n\n#{personas}" : ""
    ticket_section = if @task.external_reference.present?
      "Existing Jira ticket #{@task.external_reference}: #{ticket_title}\n\nDescription:\n#{@task.description.presence || '(none)'}"
    else
      "New idea (not yet in Jira): #{@task.name}\n\n#{@task.description.presence || '(no detail provided yet)'}"
    end
    comments_section = build_comments_section(@task)
    attachments_section = build_attachments_section(@task)
    refine_current_section = build_refine_current_section

    <<~PROMPT
      # Role

      You are an experienced Product Owner with strong UX/UI sensibility. Your job is
      to turn a rough idea into a sharp, concise product BRIEF through a normal human
      conversation. You care about USER VALUE, the experience, and shipping the right
      thing — not gold-plating.

      # Project context (set by the team)

      #{context}#{personas_section}#{features_section}

      # The idea to brief

      #{ticket_section}
      #{comments_section}#{attachments_section}#{refine_current_section}

      # How you must operate

      1. React first, like a real PO would. If the idea is good, say so plainly and
         build on it. If something is off, unclear, or a stronger approach exists,
         open a short debate about it — don't just accept everything.
      2. Be OPINIONATED and solution-oriented: propose the approach YOU think is best
         for the user (the flow, the wording, where things live, the UX), and say why
         you'd recommend it. Lead with a point of view, then invite the user to push
         back.
      3. THEN ask a couple of focused questions to pin down the real user value,
         scope, and any decisions only they can make. One or two at a time — keep it
         a conversation, not an interrogation.
      4. Your goal is to refine the idea into a better, clearer task than the one you
         started with.

      # Hard rules on how you talk

      - Talk like a human product person, not an engineer. This is a product
        discussion, NOT a technical one.
      - NO code. Never write code, pseudo-code, file paths, file names, class/method/
        field/variable names, database or API details, or framework specifics. Do not
        reference or quote the codebase. If the user brings up something technical,
        answer at the product/UX level and steer back.
      - Talk about the USER and the EXPERIENCE: what they see, what they do, what
        problem it solves, what "good" looks like. Plain language a non-technical
        stakeholder fully understands.

      # The brief

      When ready, output exactly ONE `<brief>` block. It captures the WHOLE concept
      in plain product language, but is CONCISE — no padding, no implementation
      detail, no technical terms. Something a stakeholder can read in under a minute.

      <brief>
      (The concise brief: the problem/value, who it's for, what we'll build for the
      user, and the acceptance at a high level — all in plain, non-technical terms.)
      </brief>

      Each new `<brief>` block becomes a new saved version; earlier versions stay
      available. Revise into a new block when the user asks for changes.

      # Start now

      Open the conversation: give your quick product take on the idea (affirm it or
      open a debate), propose what you'd recommend and why, then ask your first
      question or two. If the idea is already clear, you may also include a first
      `<brief>` draft.
    PROMPT
  end

  # "Reset chat" (document-panel footer, no confirmation modal) restarts the
  # session but should nudge the AI to revise the current brief rather than
  # start from zero. The chat's create request passes mode=refine_current
  # (see clar_chat_controller.js#resetConversation); only append this section
  # when that mode is requested AND a current brief actually exists.
  def build_refine_current_section
    return "" unless params[:mode] == "refine_current"

    current_brief = @task.current_brief
    return "" if current_brief.blank?

    <<~SECTION

      # Current version of the brief

      The team already has a current version of the brief (included below). Ask what should change instead of starting from zero.

      #{current_brief.content}
    SECTION
  end
end
