class ChatSessionsController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:workshop) }
  include ChatStreaming

  CHAT_PURPOSE = "refine".freeze

  # ACCESS NOTE (Workshop redesign, Task 5.1): this refine chat is the SHARED
  # Jira Tasks feature — deliberately client-accessible (require_permission!(:tasks))
  # because clients have always been able to refine tickets on the Jira Tasks board
  # (see authorization.rb: "Jira tasks + their AI features are open to clients").
  # The Workshop "details" stage REUSES this same endpoint. Clients cannot reach
  # the Workshop UI (their ProjectMembership grants Tasks alone, so every other
  # Workshop gate refuses them), and any mode=refine_current brief content injected
  # is the client's own project data, so
  # this reuse grants no new data access. Blocking clients here would regress the
  # existing Jira Tasks board behavior — an accepted, documented tradeoff. The
  # Workshop-only BRIEF chat (Task 4.2) uses the same require_permission!(:tasks).
  before_action { require_permission!(:tasks) }
  before_action :set_task

  private

  DRAFT_REGEX = %r{<draft>\s*(.*?)\s*</draft>}m

  EDITED_DESCRIPTION = "The person edited the ticket description in the panel since you last saw it. This is " \
                       "the current version (v%<version>s), and it replaces your last draft:".freeze

  # Kacper (2026-11-18): a description the person edited in the panel reaches
  # the AI with their next message, said to be theirs, so "check my edits"
  # works. The AI saw its own drafts as it wrote them; a version the person
  # made, or an AI draft they edited in place, goes once.
  def claude_message(text)
    draft = @task.current_detail_draft
    return [ text, nil ] if draft.nil? || (draft.origin == "ai" && draft.edited_at.nil?)

    stamp = "#{draft.id}:#{draft.updated_at.to_f}"
    seen = @chat_session.chat_messages.where(role: "user").order(id: :desc).detect { |message| message.data&.dig("description_seen") }
    return [ text, nil ] if seen&.data&.dig("description_seen") == stamp

    [ "#{format(EDITED_DESCRIPTION, version: draft.version)}\n\n#{description_text(draft.content)}\n\nTheir message:\n#{text}",
      { "description_seen" => stamp } ]
  end

  # A version saved from the editor is HTML: the AI reads it as plain lines.
  def description_text(content)
    return content.to_s unless content.to_s.lstrip.start_with?("<")

    Nokogiri::HTML::DocumentFragment.parse(content).css("h1, h2, h3, h4, h5, h6, p, li, pre").filter_map do |block|
      text = block.text.strip
      next if text.empty?

      case block.name
      when /\Ah\d\z/ then "## #{text}"
      when "li" then "- #{text}"
      else text
      end
    end.join("\n")
  end

  def extract_and_save_results(text)
    text.scan(DRAFT_REGEX).each do |(body)|
      next if body.blank?
      @task.task_drafts.create!(content: body.strip, source: TaskDraft::REFINE_SOURCE).make_current!
    end
  rescue StandardError => e
    Rails.logger.warn("[ChatSessions] Draft extraction failed: #{e.message}")
  end

  def investigation_step
    <<~STEP
      ## Step 1 — Investigate the code FIRST, before any question

      Before your first message to the user, do an upfront investigation of the #{project_label} codebase:

      - Read `CLAUDE.md` if it exists.
      - List the top-level `app/` directory to learn the domain.
      - Identify the 2–5 files most likely involved in this ticket (models, controllers, views, services). Read them.
      - If there are screenshots in the attachments list, read them with the `Read` tool — they usually carry critical UI context.
      #{figma_instructions_section}
      Do all of this with your tools (Read, Grep, Glob, figma MCP). Do **not** narrate any of it. Don't say "let me read X", "now let me load the Figma", "I'll check Y" — go completely silent until you're ready to post your first user-facing message. Your first message should be a 1–2 sentence PLAIN-LANGUAGE summary of what you found about how the feature works today (NO file paths / code names) followed by your first proposal to confirm, or Step 0's question when it applies. **Do not emit any text before that summary.**
    STEP
  end

  # Step 1 for a project with no checkout (ChatStreaming#chat_codebase?).
  def no_code_step
    <<~STEP
      ## Step 1 — There is no code to read

      #{NO_CODE}
      #{figma_instructions_section}
      Do **not** narrate. Your first message should be a 1–2 sentence PLAIN-LANGUAGE summary of what the brief asks for, followed by your first proposal to confirm, or Step 0's question when it applies. **Do not emit any text before that summary.**
    STEP
  end

  def build_initial_prompt
    desc = @task.description.presence || "(no description provided)"
    title = ticket_title
    ref = @task.external_reference
    attachments_section = build_attachments_section(@task)
    comments_section = build_comments_section(@task)
    refine_current_section = build_refine_current_section
    unbriefed = unbriefed_pipeline_task?

    <<~PROMPT
      # Role

      You are a specialist helping a non-technical product owner get a Jira ticket ready to implement. You have built this kind of feature many times: you know the standard way to do it, and you say so. #{chat_codebase? ? "The codebase you have access to in your working directory is the #{project_label} app — this is the project the ticket is about." : "The ticket is about the #{project_label} app."}

      # Ticket being drafted

      **#{ref}: #{title}**

      #{unbriefed ? unbriefed_framing : briefed_framing}

      ```
      #{desc}
      ```
      #{unbriefed ? project_context_section : ""}#{comments_section}#{attachments_section}#{refine_current_section}#{handoff_section}

      # How you must operate

      #{unbriefed ? unbriefed_step_zero : briefed_step_zero}

      #{chat_codebase? ? investigation_step : no_code_step}

      ## Step 2 — Propose like a specialist, in short messages

      Make sure the ticket has everything a developer and a designer need, but do
      not interrogate. For each point, propose how you would solve it and what the
      standard is ("Costs like this usually sit in the header, small and muted, so
      they don't compete with the content").
      Ask only about what a standard cannot settle: business rules, numbers only
      the owner knows, and trade-offs where both options are reasonable. For an
      integration, ask for what only the owner has: API docs, credentials, sandbox
      or production, rate limits.

      Talk PRODUCT, not implementation. You investigated the code to ground yourself,
      but you speak to a NON-TECHNICAL product owner. In the CHAT:
      - Do NOT dump code at the user: no file paths, no file names, no line numbers,
        no class/model/method/variable names, no framework/DB/API specifics.
      - It's fine to reference an existing behaviour in PLAIN terms ("the phone rule
        only kicks in for the responsible recruiter, not empty hiring-contact rows"),
        just never as a technical readout with `contact_person.rb:69` style pointers.
      - Ground each proposal in what you found, but phrased for a product person.
        Good: *"The 'at least one phone' rule only applies to the main recruiter, not
        empty contact rows, so I'd show the hint under theirs only. OK?"*
        Bad: *"`contact_person.rb:69` `at_least_one_phone` fires when
        `validate_contact_person_details?` — where should the hint render?"*

      Your messages:
      - At most three short sentences. People read them, and people read slowly.
      - One decision per message, put as a proposal to confirm ("I'd show the
        conversation's total in its header, small and muted, as $12 ($3.23 this
        month). OK?"), never an open question where a standard answer exists.
      - No lists of questions.

      Before you draft, make sure that every piece of information or control the
      ticket adds has:
      - where it shows (screen, tab, spot);
      - who sees it;
      - its default (shown or hidden, on or off);
      - one item or a total, and for which period;
      - its format, with an example;
      - empty and error states.
      Settle these from standards wherever you can, and confirm only what you
      cannot. What nobody confirmed goes into the ticket as the standard choice,
      not as an open question.

      **Never ask technical questions.** Do NOT ask: which library, which design pattern, schema/migration details, file paths, refactoring strategy. Read the code instead.

      ## Step 3 — Draft the ticket as soon as you have enough

      You judge when the picture is complete, from the conversation and from
      the code where you have it. The moment it is, write the ticket in that same
      message — do NOT ask for a go-ahead ("Should I draft it now?") and do not
      wait for one. If one last point still needs confirming, ask it, then
      write the ticket in your reply to that answer.

      Output the ticket inside `<draft>...</draft>` tags, in markdown, using this structure:

      <draft>
      (2–3 sentences, no heading: what is wrong today, what this ticket does, what comes next)

      ## <Feature or place on screen>
      (One section per feature or place where the change shows, named after it, e.g.
      "Plans (Flosis admin)", "Cost of a single item", "Settings → Consumption (admins
      only)". Bullets: what it does, where, who sees it, its default, its format with
      an example.)

      ## Rules
      - what holds across sections, with an example wherever a number is involved

      ## Out of scope
      (one line)

      ## Acceptance criteria
      - [ ] checkbox-style criteria a QA or developer can verify

      ## Open questions
      (Only if any remain, each ending with "Proposal: " and your answer — otherwise omit this section)
      </draft>

      Keep it short and concrete: no title line (the task has a name), no user
      story, no file paths or code, and no section that repeats another. External
      dependencies (API endpoints, credentials, docs links, rate limits) get a
      section of their own only when the ticket has them.

      The `<draft>` and `</draft>` markers are **mandatory** — the system uses them to save the draft as a versioned record the user can copy into Jira.

      IMPORTANT: the block is REMOVED from the chat and rendered in the **Description panel on the right**. So the reader never sees the ticket where you wrote it, and a lead-in like "Here's the refined ticket:" leaves them staring at a sentence with nothing after it. Outside the tags write one short line that says WHERE it went and how to compare versions — e.g. "The refined description is in the Description panel on the right; use the version selector at the top of that panel to switch between versions." Vary the wording, keep it to one sentence, and never write as though the ticket were in the chat.

      ## Step 4 — Revisions

      If the user asks for changes after the first draft, produce a fully revised ticket in a **new** `<draft>...</draft>` block — don't show a diff and don't reuse the old block. Each `<draft>` block becomes a new saved version in that same panel, and the earlier ones stay available in its version selector — say so in your one-line note, so the reader knows the previous wording was not lost.

      # Start now

      Do your upfront investigation silently, then post your first message: a brief 1–2 sentence plain-language summary of what you found, then your first proposal to confirm, or Step 0's question when it applies. No lists of questions.#{handoff_opening}
    PROMPT
  end

  # Create Tasks → Setup can switch the Briefing step off, which makes this
  # chat the first AI pass over a pipeline task. With no brief, nobody has
  # shaped the why yet: the prompt says so and carries the project context the
  # briefing chat would have read. Tasks on the Jira Tasks board (not in the
  # pipeline) and briefed tasks keep the briefed framing.
  def unbriefed_pipeline_task?
    @task.in_pipeline? && !@task.briefs.exists?
  end

  def briefed_framing
    <<~TEXT.chomp
      The briefing stage is ALREADY DONE. Below is the agreed BRIEF — the product
      owner and a Product Owner AI already worked out the problem, who it's for,
      what we build, scope, and acceptance. Treat it as DECIDED context, not a
      blank starting point:
    TEXT
  end

  def unbriefed_framing
    <<~TEXT.chomp
      There was no briefing step for this ticket — this chat is the first pass
      over it. Below is the description as the team wrote it; it may be short or
      rough:
    TEXT
  end

  def briefed_step_zero
    <<~TEXT.chomp
      ## Step 0 — Read the brief; do NOT re-ask what it already answers

      The brief above already settles the WHY, WHO, WHAT, scope, and acceptance.
      Do NOT re-litigate those — asking "what's the main reason for this?" when the
      brief states it is exactly the kind of question that makes this feel like a
      waste of the user's time. Your job now is to fill the IMPLEMENTATION gaps the
      brief leaves open (edge cases, exact behaviour, data/permission specifics,
      ordering, error handling) so a developer can build it — not to re-confirm the
      premise. If the brief truly leaves the goal ambiguous, you may confirm it in
      ONE sentence — but never open with a question the brief has already answered.
    TEXT
  end

  def unbriefed_step_zero
    <<~TEXT.chomp
      ## Step 0 — Make sure the goal is clear, then move on

      Nobody has shaped the WHY yet. If the description already says who this is
      for and what problem it solves, do NOT re-ask it. If it doesn't, settle that
      first in one or two short questions — then fill the IMPLEMENTATION gaps (edge
      cases, exact behaviour, data/permission specifics, ordering, error handling)
      so a developer can build it. Use the project context above to know who the
      users are and what the app already does.
    TEXT
  end

  # The same two team-maintained inputs the briefing chat reads
  # (BriefChatSessionsController#build_initial_prompt). Empty when neither is set.
  def project_context_section
    project = @task.project
    sections = []
    if (personas = project.briefing_personas.presence)
      sections << "# Who uses this app & our perspective (set by the team)\n\n#{personas}"
    end
    if (features = project.features_summary.presence)
      sections << "# What the app already does (auto-maintained; read this so you don't propose things that already exist)\n\n#{features}"
    end
    sections.empty? ? "" : "\n#{sections.join("\n\n")}\n"
  end

  # "Reset chat" (document-panel footer, no confirmation modal) restarts the
  # session but should nudge the AI to revise the current AI draft rather than
  # start from zero. The chat's create request passes mode=refine_current
  # (see clar_chat_controller.js#resetConversation); only append this section
  # when that mode is requested. Also surfaces the current BRIEF (mirrors
  # BriefChatSessionsController#build_refine_current_section) so the details
  # session picks up where briefing left off.
  def build_refine_current_section
    return "" unless params[:mode] == "refine_current"

    current_brief = @task.current_brief
    return "" if current_brief.blank?

    <<~SECTION

      # Current version of the brief

      Briefed version is in. I've re-read the relevant services and any designs attached. The team's current brief is included below — ask what should change instead of starting from zero.

      #{current_brief.content}
    SECTION
  end

  # Configuration -> Integrations -> Figma toggle (Task 9.2, figma_read_enabled):
  # only instruct the AI to read Figma frames when THIS project has opted in.
  # Gated on the very predicate ProjectMcpConfig writes the figma server on, so
  # the prompt can never name a tool the run was not handed. Returns "" when
  # disabled so the investigation list simply omits the Figma bullet.
  def figma_instructions_section
    return "" unless ProjectCredentials.new(@task.project).figma_configured?

    <<~FIGMA.strip
      - **Figma links.** If the ticket description or any comment contains a Figma URL (figma.com/design/... or figma.com/file/...), you have access to a Figma MCP server with an authenticated read-only token. For **every** Figma URL you must do BOTH:
        1. Call `mcp__figma__get_figma_data` for the node tree (text, structure, component names).
        2. Call `mcp__figma__download_figma_images` to download the rendered PNGs of the relevant frames and then `Read` those PNG files. Visual details (color coding, spacing, micro-copy in icons, badges, empty states) are routinely the deciding factor for UI tickets and are NOT in the node tree alone.

        Don't stop after the node tree. If the file is too large for a single PNG, request individual frame IDs separately and read each one. If a node hits Read's pixel limit, ask for a smaller scale or fetch a sub-frame — don't give up.
    FIGMA
  end
end
