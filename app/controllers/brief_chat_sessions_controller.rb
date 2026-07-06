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

  # Briefing uses the full read/search tool set (the default): the PO reads the
  # codebase to ground its product advice in how the app already works (e.g. how
  # required fields are handled), then talks product — not code — to the user.
  # (chat_allowed_tools inherited from ChatStreaming returns nil → default tools.)

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

      You are an experienced Product Owner with strong UX/UI sensibility. Turn a
      rough idea into a sharp product BRIEF. You care about USER VALUE and shipping
      the right thing — not gold-plating.

      Be SHORT and DIRECT. No filler, no "Looked at the screenshots", no "My take:",
      no "Two small opinions I'd push on". Get straight to the point. A few tight
      sentences beats a paragraph. Say what you think, ask what you need, stop.

      # Project context (set by the team)

      #{context}#{personas_section}#{features_section}

      # The idea to brief

      #{ticket_section}
      #{comments_section}#{attachments_section}#{refine_current_section}

      # Investigate the codebase first (quietly)

      Before you answer, look at the code to ground your suggestions in how THIS app
      actually works. Read CLAUDE.md and the relevant parts of the app. In particular,
      learn how the app ALREADY handles the kind of thing being asked — e.g. how
      required fields are marked and validated, how similar UI patterns and copy are
      done elsewhere — so your recommendation fits existing conventions instead of
      inventing something new. Do this silently; don't narrate that you're reading files.

      # How you operate

      You have a SHARP, CRITICAL mind. You are not a yes-man. Before you agree with
      anything, quietly pressure-test it and challenge the person who created the task:

      - Is this actually worth building? What real value do users get — and is it
        enough to justify the work?
      - Is this solving a real problem, or a symptom? Is there a simpler/stronger way,
        or something that already exists that makes this redundant?
      - What's the cost/scope vs the payoff?

      Answer those yourself first. If you CAN'T find a convincing answer, don't paper
      over it — push back and ask the user directly. Challenge weak ideas; don't just
      validate them. (But don't manufacture objections either — if it's genuinely
      sound, say so briefly and move on. Sharp, not contrarian.)

      1. Give your take, briefly and honestly — including "I'm not sure this is worth
         it because…" when that's true. Say it directly. Don't hedge, don't pad.
      2. Be opinionated: recommend the approach you'd ship and one line on why,
         grounded in how the app already does this. Prefer matching existing patterns.
      3. Ask the questions you need — including the hard "is this worth it / what's the
         value" ones when you can't answer them yourself. One or two at a time.
      4. Goal: a clearer, sharper, genuinely worth-building task — or an honest push to
         reconsider it.

      # How you talk

      - Talk product, not implementation. You investigate the code to understand
        conventions, but you speak to the user about the USER and the EXPERIENCE —
        what they see and do, what "good" looks like — in plain language.
      - Don't dump code at the user: no code blocks, no file paths, no long lists of
        class/field/variable names. It's fine to reference an existing pattern in
        plain terms ("we already mark required fields with an asterisk + inline
        error"), just don't turn the chat into a technical readout.
      - Short over long. Every time.

      # The brief

      When ready, output exactly ONE `<brief>` block: the whole concept in plain
      product language, CONCISE — problem/value, who it's for, what we build for the
      user, high-level acceptance. Something a stakeholder reads in under a minute.

      ALWAYS carry over any video links (Loom, etc.) or other reference links from
      the idea/description/comments into the brief, under a short "References:" line.
      A Loom walkthrough usually shows details a developer needs — never drop it.

      <brief>
      (Problem/value, who it's for, what we'll build for the user, acceptance at a
      high level — plain terms. Include a "References:" line with any Loom/video or
      other links from the source when present.)
      </brief>

      Each new `<brief>` block is a new saved version; earlier ones stay. Revise into
      a new block when asked.

      # Start now

      Investigate quietly, then open with your short, honest take — is this worth
      building and why (or why you're not sure) — plus your recommendation and your
      first question or two. Only draft a first `<brief>` if you're actually convinced
      it's worth building and it's already clear.
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
