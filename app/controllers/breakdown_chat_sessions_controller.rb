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

  before_action :require_client_or_employee!
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
      - **Figma links.** For every Figma URL in the description/comments, call BOTH `mcp__figma__get_figma_data` (node tree) AND `mcp__figma__download_figma_images` (then `Read` the PNGs). Visual scope (number of screens, states, components) drives the estimate. **Note which frame/screen belongs to which flow** (e.g. which frames are the Manager view vs the Employee view) — you'll attach the relevant Figma link to the sub-task that builds those screens. A Figma URL can point at a specific frame via `?node-id=...`; preserve that node-id when a slice maps to a specific frame, otherwise use the file URL.

      Do all of this with your tools. Do **not** narrate it — go silent until you post the breakdown.

      ## Step 2 — Produce the estimate & breakdown immediately

      Default to giving a concrete result on your first turn. Only if the task is genuinely ambiguous in a way that changes the estimate by more than one Fibonacci step should you ask 1–2 short questions first — otherwise commit to a breakdown.

      ## Estimation & breakdown rules — read carefully

      - **Each sub-task's points MUST be a Fibonacci value: 1, 2, 3, 5, 8, 13, 21.** Never any other number for a sub-task.
      - Each sub-task should be **≤ 13**, and **21 is the absolute maximum**. If a slice would exceed 21, split it further.
      - **Do NOT cap the overall total.** The whole feature's size is simply the SUM of the slices and may well be far more than 21 (a big epic might total 40, 60+). Don't shrink slices or drop scope to make the total "fit" — size each slice honestly and let the total be whatever it adds up to. (The system computes and displays the total from the slices; you don't need to total it yourself.)
      - Sub-tasks are **vertical slices**: each is mostly stand-alone and delivers end-to-end value on its own, and together they build the whole feature.
      - **FORBIDDEN: layer-based splits.** Do NOT create tasks like "set up the database", "build the backend", then "build the frontend". Each sub-task must be independently shippable and cut across the stack as needed.
      - Prefer splitting by **role / user flow / domain** (e.g. for an HR onboarding feature: manager flow, employee flow, buddy flow, visibility dashboard). That yields naturally independent slices.
      - If the feature is genuinely small, set `needs_breakdown` to false, estimate the whole thing, and leave `subtasks` empty — don't force a split.
      - Each sub-task needs a concise Jira-style **title**, **points**, and a **description of the business logic** for a developer: what they must deliver and why, enough that they know what to build — but NOT implementation/library/schema detail.
      - Each sub-task MUST include **`acceptance_criteria`**: a list of 2–5 concrete, verifiable statements (a QA or developer can check each off) that define "done" for THAT slice specifically. Phrase them as testable outcomes, not implementation steps. Every broken-down sub-task needs at least one — a slice without acceptance criteria will be rejected.
      - Each sub-task MUST include **`figma_links`**: the relevant Figma link(s) for the screens that slice builds, taken from the Figma URLs in the ticket. Attach the specific frame (preserve `?node-id=...` when you identified the exact frame for that flow); if the design covers the whole flow in one file, use the file URL. If the ticket has **no** Figma links at all, use an empty array `[]`. Do not invent URLs — only use links that appear in the ticket description/comments.
      - Use `order` (1-based) and `depends_on` (list of sub-task titles that must come first) to express sequence. Most slices should be independent; keep dependencies minimal.
      - Set `warning` when something is off: a slice still feels > 21 and should be split further, or the scope is unusually risky/unclear. A large total is NOT a problem worth warning about on its own — big features are big. Otherwise leave it null.

      ## Output format — mandatory

      Output exactly ONE `<breakdown>` block containing PURE JSON (no markdown, no comments, no trailing prose inside the tags). Use this exact shape:

      <breakdown>
      {
        "needs_breakdown": true,
        "strategy": "One or two sentences on how you split it (e.g. by role: manager / employee / buddy).",
        "warning": null,
        "subtasks": [
          {
            "title": "Manager: assign checklists when hiring an employee",
            "points": 8,
            "description": "Business logic the developer must deliver and why. No implementation detail.",
            "acceptance_criteria": [
              "Manager can assign an onboarding checklist to a newly hired employee from the hire flow",
              "Assigned checklist appears on the employee's onboarding with the correct tasks",
              "A manager without permission cannot assign checklists"
            ],
            "figma_links": [
              { "label": "Manager view", "url": "https://www.figma.com/design/abc/HR?node-id=123-456" }
            ],
            "order": 1,
            "depends_on": []
          }
        ]
      }
      </breakdown>

      - For a broken-down task, OMIT `total_points` (or it will be ignored) — the system sums the slices for you, and the total may exceed 21.
      - Every sub-task `points` MUST be from {1,2,3,5,8,13,21}. A sub-task with any other number will be rejected by the system.
      - For a small task that doesn't need splitting: `"needs_breakdown": false`, `"subtasks": []`, and include `"total_points"` = the whole-task estimate (which MUST itself be a Fibonacci value).
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
