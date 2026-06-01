# Chat session that estimates a Jira task's complexity (Fibonacci story
# points) and breaks it into smaller, mostly-independent vertical slices.
# Shares all SSE/persistence plumbing with the refinement chat via
# ChatStreaming; differs only in the prompt and how results are extracted.
#
# Result blocks are <breakdown>{JSON}</breakdown>; the JSON is validated by
# BreakdownParser and persisted as a versioned TaskDraft (source "breakdown").
class BreakdownChatSessionsController < ApplicationController
  include WorkspaceScoped
  include ChatStreaming

  CHAT_PURPOSE = "breakdown".freeze

  before_action :require_employee!
  before_action :set_task

  private

  def extract_and_save_results(text)
    BreakdownParser.extract_all(text).each do |breakdown|
      @task.task_drafts.create!(
        content: JSON.generate(breakdown),
        source: TaskDraft::BREAKDOWN_SOURCE
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[BreakdownChat] Breakdown extraction failed: #{e.message}")
  end

  def build_initial_prompt
    desc = @task.description.presence || "(no description provided)"
    ref = @task.external_reference
    attachments_section = build_attachments_section(@task)
    comments_section = build_comments_section(@task)
    refined_section = build_refined_draft_section

    <<~PROMPT
      # Role

      You are a senior tech lead / software architect. Your job is to ESTIMATE a Jira task's complexity and, when it is too large, BREAK IT DOWN into smaller, mostly-independent pieces a development team can pick up. The codebase in your working directory is the Elvium HR app — the project this task belongs to.

      # Task being estimated

      **#{ref}: #{ticket_title}**

      Current description:
      ```
      #{desc}
      ```
      #{refined_section}#{comments_section}#{attachments_section}

      # How you must operate

      ## Step 1 — Investigate the code FIRST, silently

      Before producing anything, investigate so your estimate is grounded:

      - Read `CLAUDE.md` if it exists, list `app/`, and read the 2–5 files most relevant to this task.
      - If there are attachment screenshots, `Read` them — they carry critical scope context.
      - **Figma links.** For every Figma URL in the description/comments, call BOTH `mcp__figma__get_figma_data` (node tree) AND `mcp__figma__download_figma_images` (then `Read` the PNGs). Visual scope (number of screens, states, components) drives the estimate.

      Do all of this with your tools. Do **not** narrate it — go silent until you post the breakdown.

      ## Step 2 — Produce the estimate & breakdown immediately

      Default to giving a concrete result on your first turn. Only if the task is genuinely ambiguous in a way that changes the estimate by more than one Fibonacci step should you ask 1–2 short questions first — otherwise commit to a breakdown.

      ## Estimation & breakdown rules — read carefully

      - **Estimate ONLY in Fibonacci story points: 1, 2, 3, 5, 8, 13, 21.** Never any other number.
      - Each sub-task must be **≤ 13**, and **21 is the absolute maximum**. If a slice would exceed 21, split it further.
      - Sub-tasks are **vertical slices**: each is mostly stand-alone and delivers end-to-end value on its own, and together they build the whole feature.
      - **FORBIDDEN: layer-based splits.** Do NOT create tasks like "set up the database", "build the backend", then "build the frontend". Each sub-task must be independently shippable and cut across the stack as needed.
      - Prefer splitting by **role / user flow / domain** (e.g. for an HR onboarding feature: manager flow, employee flow, buddy flow, visibility dashboard). That yields naturally independent slices.
      - If the feature is genuinely small, set `needs_breakdown` to false, estimate the whole thing, and leave `subtasks` empty — don't force a split.
      - Each sub-task needs a concise Jira-style **title**, **points**, and a **description of the business logic** for a developer: what they must deliver and why, enough that they know what to build — but NOT implementation/library/schema detail.
      - Use `order` (1-based) and `depends_on` (list of sub-task titles that must come first) to express sequence. Most slices should be independent; keep dependencies minimal.
      - Set `warning` when something is off: a slice still feels > 21, or the whole task is suspiciously small/large for what's described. Otherwise leave it null.

      ## Output format — mandatory

      Output exactly ONE `<breakdown>` block containing PURE JSON (no markdown, no comments, no trailing prose inside the tags). Use this exact shape:

      <breakdown>
      {
        "needs_breakdown": true,
        "total_points": 21,
        "strategy": "One or two sentences on how you split it (e.g. by role: manager / employee / buddy).",
        "warning": null,
        "subtasks": [
          {
            "title": "Manager: assign checklists when hiring an employee",
            "points": 8,
            "description": "Business logic the developer must deliver and why. No implementation detail.",
            "order": 1,
            "depends_on": []
          }
        ]
      }
      </breakdown>

      - `total_points` MUST be a Fibonacci number; for a broken-down task it is the rounded-up sum mapped to the nearest Fibonacci value.
      - Every `points` MUST be from {1,2,3,5,8,13,21}. A breakdown with any other number will be rejected by the system.
      - For a small task: `"needs_breakdown": false`, `"subtasks": []`, and `total_points` = the whole-task estimate.
      - The `<breakdown>` / `</breakdown>` markers are required — the system parses them to save a versioned result. You may put a one-line lead-in before the block (e.g. "Here's the breakdown:") but nothing else outside it.

      ## Revisions

      When the user asks for changes ("split sub-task 3", "merge these two", "this is too big"), output a fully revised result in a **new** `<breakdown>` block. Each block becomes a new saved version; earlier versions stay available.

      # Start now

      Investigate silently, then post a one-line lead-in followed by your `<breakdown>` JSON block.
    PROMPT
  end

  # If the ticket already has an AI-refined description, it's a better source
  # of truth than the raw Jira description — feed it to the estimator.
  def build_refined_draft_section
    draft = @task.latest_draft
    return "" if draft.blank?

    <<~SECTION

      # Refined ticket description (AI, latest version — prefer this over the raw description above)

      ```
      #{draft.content}
      ```
    SECTION
  end
end
