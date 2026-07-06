class ChatSessionsController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:workshop) }
  include ChatStreaming

  CHAT_PURPOSE = "refine".freeze

  # ACCESS NOTE (Workshop redesign, Task 5.1): this refine chat is the SHARED
  # Jira Tasks feature — deliberately client-accessible (require_client_or_employee!)
  # because clients have always been able to refine tickets on the Jira Tasks board
  # (see authorization.rb: "Jira tasks + their AI features are open to clients").
  # The Workshop "details" stage REUSES this same endpoint. Clients cannot reach
  # the Workshop UI (redirect_clients_to_jira bounces them to /jira_tasks), and any
  # mode=refine_current brief content injected is the client's own project data, so
  # this reuse grants no new data access. Blocking clients here would regress the
  # existing Jira Tasks board behavior — an accepted, documented tradeoff. The
  # Workshop-only BRIEF chat (Task 4.2) uses the stricter require_workshop_member!.
  before_action :require_client_or_employee!
  before_action :set_task

  private

  DRAFT_REGEX = %r{<draft>\s*(.*?)\s*</draft>}m

  def extract_and_save_results(text)
    text.scan(DRAFT_REGEX).each do |(body)|
      next if body.blank?
      @task.task_drafts.create!(content: body.strip, source: TaskDraft::REFINE_SOURCE).make_current!
    end
  rescue StandardError => e
    Rails.logger.warn("[ChatSessions] Draft extraction failed: #{e.message}")
  end

  def build_initial_prompt
    desc = @task.description.presence || "(no description provided)"
    title = ticket_title
    ref = @task.external_reference
    attachments_section = build_attachments_section(@task)
    comments_section = build_comments_section(@task)
    refine_current_section = build_refine_current_section

    <<~PROMPT
      # Role

      You are a senior product/engineering partner helping a non-technical product owner draft a complete, ready-to-implement Jira ticket. The codebase you have access to in your working directory is the Elvium HR app — this is the project the ticket is about.

      # Ticket being drafted

      **#{ref}: #{title}**

      Current description:
      ```
      #{desc}
      ```
      #{comments_section}#{attachments_section}#{refine_current_section}

      # How you must operate

      ## Step 1 — Investigate the code FIRST, before any question

      Before your first message to the user, do an upfront investigation of the Elvium codebase:

      - Read `CLAUDE.md` if it exists.
      - List the top-level `app/` directory to learn the domain.
      - Identify the 2–5 files most likely involved in this ticket (models, controllers, views, services). Read them.
      - If there are screenshots in the attachments list, read them with the `Read` tool — they usually carry critical UI context.
      #{figma_instructions_section}
      Do all of this with your tools (Read, Grep, Glob, figma MCP). Do **not** narrate any of it. Don't say "let me read X", "now let me load the Figma", "I'll check Y" — go completely silent until you're ready to post your first user-facing message. Your first message should be a 1–2 sentence PLAIN-LANGUAGE summary of what you found about how the feature works today (NO file paths / code names) followed by your first clarifying question. **Do not emit any text before that summary.**

      ## Step 2 — Ask product/UX/business questions only, one at a time

      Talk PRODUCT, not implementation. You investigated the code to ground yourself,
      but you speak to a NON-TECHNICAL product owner. In the CHAT:
      - Do NOT dump code at the user: no file paths, no file names, no line numbers,
        no class/model/method/variable names, no framework/DB/API specifics.
      - It's fine to reference an existing behaviour in PLAIN terms ("the phone rule
        only kicks in for the responsible recruiter, not empty hiring-contact rows"),
        just never as a technical readout with `contact_person.rb:69` style pointers.
      - Ground each question in what you found, but phrased for a product person.
        Good: *"The 'at least one phone' rule only applies to the main recruiter, not
        empty contact rows — should the hint show under every contact or just theirs?"*
        Bad: *"`contact_person.rb:69` `at_least_one_phone` fires when
        `validate_contact_person_details?` — where should the hint render?"*

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

      ## Implementation pointers (for the developer)
      A few plain-language pointers to where this lives and what to touch, so the
      developer has a head start — kept brief. A file/area name is fine here IF it
      genuinely helps a dev (this section is for them, not the PO), but keep it to a
      short pointer list, not a code walkthrough. Omit if you're not confident.

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
  # only instruct the AI to read Figma frames when the workspace has opted in.
  # Access itself is a server-side MCP config either way — this toggle purely
  # controls whether Details Gathering tells the AI to use it. Returns "" when
  # disabled so the investigation list simply omits the Figma bullet.
  def figma_instructions_section
    return "" unless @task.project.workspace.figma_read_enabled

    <<~FIGMA.strip
      - **Figma links.** If the ticket description or any comment contains a Figma URL (figma.com/design/... or figma.com/file/...), you have access to a Figma MCP server with an authenticated read-only token. For **every** Figma URL you must do BOTH:
        1. Call `mcp__figma__get_figma_data` for the node tree (text, structure, component names).
        2. Call `mcp__figma__download_figma_images` to download the rendered PNGs of the relevant frames and then `Read` those PNG files. Visual details (color coding, spacing, micro-copy in icons, badges, empty states) are routinely the deciding factor for UI tickets and are NOT in the node tree alone.

        Don't stop after the node tree. If the file is too large for a single PNG, request individual frame IDs separately and read each one. If a node hits Read's pixel limit, ask for a smaller scale or fetch a sub-frame — don't give up.
    FIGMA
  end
end
