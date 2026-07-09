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

      What you learn from the code is FUEL for your product advice — it is NOT
      something you report. The person you're talking to is a non-technical Product
      Owner deciding whether this is worth building. They do not care how it's wired.
      So:

      - NEVER say "the code shows", "code confirms", "the code surfaced", "I looked at
        the code", or anything that reveals you read the repo. Just state your product
        view as if you already knew the product.
      - NEVER name mechanisms, options, methods, branches, files, locales, or config
        (no "the native `hint:` option", no "there's a work-in-progress branch", no
        "the DA locale is missing the key"). These are invisible to the PO.
      - Translate every code fact into a USER-FACING consequence. A technical gap only
        matters if it changes what a user experiences — so say the user thing:
          BAD:  "The DA locale is missing this translation."
          GOOD: "Right now this only works in English — a Danish user would see an
                 English error. Want Danish in scope, or is English fine for now?"
          BAD:  "There's a WIP branch doing this via the standard hint option."
          GOOD: "We already show a small grey helper line under fields — I'd reuse
                 that look rather than add a new icon."

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

      - This is a BUSINESS conversation about whether the feature is worth building
        and what it should do for the user — NOT a developer status update. Talk about
        the USER and the EXPERIENCE: what they see and do, what "good" looks like, what
        it's worth. Plain language a non-technical stakeholder reads and nods along to.
      - No code blocks, no file paths, no class/field/option/branch/locale names, no
        "the code…". Reference an existing pattern only in plain user terms ("we
        already mark required fields with an asterisk + inline error").
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
