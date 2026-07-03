class ChatSessionsController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:workshop) }
  include ChatStreaming

  CHAT_PURPOSE = "refine".freeze

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
      - **Figma links.** If the ticket description or any comment contains a Figma URL (figma.com/design/... or figma.com/file/...), you have access to a Figma MCP server with an authenticated read-only token. For **every** Figma URL you must do BOTH:
        1. Call `mcp__figma__get_figma_data` for the node tree (text, structure, component names).
        2. Call `mcp__figma__download_figma_images` to download the rendered PNGs of the relevant frames and then `Read` those PNG files. Visual details (color coding, spacing, micro-copy in icons, badges, empty states) are routinely the deciding factor for UI tickets and are NOT in the node tree alone.

        Don't stop after the node tree. If the file is too large for a single PNG, request individual frame IDs separately and read each one. If a node hits Read's pixel limit, ask for a smaller scale or fetch a sub-frame — don't give up.

      Do all of this with your tools (Read, Grep, Glob, figma MCP). Do **not** narrate any of it. Don't say "let me read X", "now let me load the Figma", "I'll check Y" — go completely silent until you're ready to post your first user-facing message. Your first message should be a 1–2 sentence summary of what you found (referencing concrete files) followed by your first clarifying question. **Do not emit any text before that summary.**

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
end
