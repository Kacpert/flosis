# AI Estimate & Breakdown

## Summary

Add a new AI capability to the Jira task detail view that **estimates a task's complexity** in story points (Fibonacci: 1, 2, 3, 5, 8, 13, 21) and **breaks a too-large task into smaller, mostly-independent vertical slices** that together build the whole feature. Small tasks are only estimated — no breakdown is forced.

The feature lives on a dedicated two-panel sub-page `/jira_tasks/:id/breakdown`:
- **Left panel (always visible):** the rendered breakdown card — total estimate, breakdown strategy, suggested order, warnings, and the list of sub-tasks with expandable developer-facing descriptions. A version dropdown in the header allows read-only viewing of older versions.
- **Right panel (chat):** a Claude chat where the user refines the breakdown ("split sub-task 3 further", "merge these two", "this is too big"). Each correction regenerates the breakdown as a **new version**.

Entry point: a new **"AI estimate & breakdown"** button in the Details sidebar of `show.html.erb`, next to the existing "AI refined ticket description" button.

**Deployment context:** Single-user local development tool. The Rails server and Claude CLI run on the same machine under the same user account. No multi-user/production concerns. **No write-back to Jira** — the result is preview/copy-only; the human manually creates the tasks in Jira.

## Goals & Non-Goals

**Goals**
- Estimate complexity in Fibonacci story points only.
- Break large tasks into stand-alone vertical slices; each ≤ 13, absolute max 21.
- Avoid horizontal/layer-based splits ("set up DB", then "build frontend").
- Versioned results so we can look back at earlier breakdowns (read-only).
- Reuse the existing Claude/SSE/draft infrastructure with minimal new surface area.

**Non-Goals (YAGNI)**
- No write-back to Jira (no creating sub-tasks, no setting story points via API).
- No separate `task_breakdowns`/`subtasks` relational tables (reuse `task_drafts`).
- No "restore version" that mutates chat state — version dropdown is view-only.
- No editing of generated sub-tasks in-place (refinement happens via chat).

## Data Model

Reuse existing tables; one new column.

### Migration
- **`chat_sessions.purpose`** — string, `null: false`, default `"refine"`. Distinguishes a refinement session from a breakdown session. Backfill existing rows to `"refine"`.
  - Replace/extend the active-session uniqueness handling so refine and breakdown sessions for the same task coexist. Index on `[task_id, purpose, status]`.
- **`task_drafts.source`** — already exists (today only `"ai"`). No schema change. Breakdown versions are stored with `source: "breakdown"`; refinement drafts remain `source: "ai"`.

### TaskDraft reuse
- A breakdown version is one `TaskDraft` row with `source: "breakdown"` and `content` = **JSON** (schema below), not markdown.
- Renderers branch on `source`: `"ai"` → markdown ticket description (unchanged); `"breakdown"` → parse JSON → breakdown card.
- Versioning is free: each generation/correction = a new immutable row. `(task_id, created_at)` index + `newest_first` scope already exist.
- **Every place that currently fetches "latest draft" / lists drafts must filter by `source`** so the refinement modal never shows breakdown JSON and vice-versa. Concretely: keep `Task#latest_draft` as the refinement accessor but scope it to `source: "ai"`, and add `Task#latest_breakdown` scoped to `source: "breakdown"`. Audit existing callers of `latest_draft` and `task_drafts#index` and confirm each is correctly scoped (the refinement modal/controller use the `"ai"` scope; breakdown UI uses the `"breakdown"` scope).

### Breakdown JSON schema (stored in `task_drafts.content`)
```json
{
  "needs_breakdown": true,
  "total_points": 34,
  "strategy": "Split by role: manager / employee / buddy + shared foundation.",
  "warning": null,
  "subtasks": [
    {
      "title": "Manager: assign checklists when hiring",
      "points": 8,
      "description": "Business logic the developer must deliver (what & why, not how).",
      "order": 1,
      "depends_on": []
    }
  ]
}
```
- `needs_breakdown: false` → small task; render "This task does not need a breakdown. Estimate: X". `subtasks` may be empty.
- `total_points` → sum across sub-tasks (or the whole-task estimate when not broken down).
- `strategy` → 1–2 sentences explaining how the AI thought about the split.
- `warning` → non-empty when a slice > 21 ("too big, split further") or the whole thing looks suspiciously small/large.
- `order` + `depends_on` → suggested sequence / which slices are foundational vs. parallelizable.
- `points` ∈ {1, 2, 3, 5, 8, 13, 21} — enforced by validation.

## Backend

### Shared streaming concern — `ChatStreaming`
`chat_sessions_controller.rb` (~280 lines) currently mixes SSE streaming/persistence with prompt-building. Extract the SSE + persist + block-extraction machinery into a shared concern (or service) parameterized by:
- `purpose` (`"refine"` | `"breakdown"`)
- `build_prompt` (initial + follow-up)
- block marker + extractor (`<draft>` → markdown `source:"ai"`; `<breakdown>` → validated JSON `source:"breakdown"`)

Both the existing refine controller and the new breakdown controller consume this concern. They differ only in prompt, marker, and `source`. `ClaudeCliService` is **unchanged** (it is prompt-agnostic; same pre-allowed tools: Read, Glob, Grep, WebFetch, Figma MCP).

### Routes (`config/routes.rb`, nested in `resources :jira_tasks`)
```ruby
get  :breakdown, to: "task_breakdowns#show"          # two-panel sub-page
resources :task_breakdowns, only: [:index]            # JSON list of versions
resource  :breakdown_chat_session,
          only: [:create, :show, :destroy],
          controller: "breakdown_chat_sessions" do
  post :message
end
```
(Exact controller/route names finalized in the plan; intent: no duplication of `ChatSessionsController`.)

### Controllers
- **`TaskBreakdownsController#show`** — renders `/jira_tasks/:id/breakdown`. Loads the latest `task_draft` with `source: "breakdown"`. If present → render it on the left immediately. If absent → the page signals the frontend to auto-trigger generation.
- **`TaskBreakdownsController#index`** — JSON list of breakdown versions (clone of `task_drafts#index`, filtered to `source: "breakdown"`): `[{id, content(parsed), created_at, created_at_display}]`.
- **`BreakdownChatSessionsController`** (`create`, `show`, `message`, `destroy`) — uses `ChatStreaming` with `purpose: "breakdown"`.

### Generation flow
1. Enter `/breakdown`. If no version exists, the frontend POSTs `breakdown_chat_session#create` → SSE.
2. `ClaudeCliService.send_initial_streaming(prompt: build_breakdown_prompt)` — silent investigation, then immediately a first version in one `<breakdown>{JSON}</breakdown>` block.
3. SSE streams assistant text into the right (chat) panel; left panel shows "Generating…".
4. On `result`: extract JSON from `<breakdown>`, **validate**, persist as `TaskDraft(source:"breakdown")`, render the left panel.
5. A chat correction → `send_message_streaming` → new `<breakdown>` → new version → left panel re-renders the latest.

### Validation
On extraction, before persisting a version:
- Content is a single well-formed JSON object matching the schema.
- Every `subtasks[].points` ∈ {1, 2, 3, 5, 8, 13, 21}.
- Either `needs_breakdown: false`, or `subtasks` has ≥ 1 entry.
If invalid: **do not persist**. Surface a message in the chat and let the AI correct (the prompt states points MUST be from the allowed set). The left panel stays on the previous version, or shows a "couldn't generate — try again" state if there is none.

## AI Prompt

Modeled on the existing `build_initial_prompt` (silent investigation, no narration), with a new objective.

**Role:** Senior tech lead / architect estimating and splitting a Jira task into smaller, independent pieces for a dev team.

**Step 1 — Silent investigation** (as today): read `CLAUDE.md`, scan `app/`, read key files, read task attachments from disk, fetch Figma (node tree + PNGs) if URLs present. No narration.

**Step 2 — Immediately produce the first version** (per decision "immediate version, then correct"). Only if the task is genuinely unclear → ask at most 1–2 key questions; otherwise default to a concrete result.

**Breakdown rules (core requirements):**
- Estimate ONLY in Fibonacci: 1, 2, 3, 5, 8, 13, 21. No other numbers.
- Each sub-task ≤ 13, absolute max 21. If something exceeds 21 → split further.
- Sub-tasks are **vertical slices** (stand-alone, deliver end-to-end value) that **together** build the whole feature.
- **Forbidden:** layer-based splits — NOT "prepare database", NOT "do the backend" then "do the frontend". Each sub-task should be reasonably independent and independently shippable.
- Prefer splitting by **role / user flow / domain** (e.g. for an HR onboarding feature: manager flow, employee flow, buddy flow, visibility dashboard) because that yields independent vertical slices.
- If the feature is small → `needs_breakdown: false`, estimate the whole, do not force a split.
- Each sub-task: concise Jira-style **title** + **story points** + **business-logic description** for a developer (what & why — not implementation detail, but enough that a dev knows what to build) + `order` + `depends_on`.
- Whole-card fields: `total_points`, `strategy` (1–2 sentences), order (via `order`/`depends_on`), `warning` (too big / too small).

**Output format (enforced):** exactly one `<breakdown>…</breakdown>` block containing **pure JSON** per the schema. The prompt includes a full JSON example and stresses: points MUST be from the allowed set; output must be parsable JSON with no surrounding markdown.

**Task context injection** (as today): Jira key, title, description (plain + ADF), attachment disk paths, comments. **If a latest refinement draft exists** (`source:"ai"`), include it as a higher-quality requirements source than the raw description.

## Frontend

New sub-page `app/views/jira_tasks/breakdown.html.erb`, two-column layout reusing M3 tokens and `_chat_panel` patterns.

### Left panel — `breakdown_controller.js` (Stimulus)
- Header: task title + **version dropdown** (v1…vN with dates; "Latest" active; selecting an older one is read-only preview).
- "Generating…" state: skeleton / pulsing placeholder cards while the AI builds the first version.
- Breakdown card render:
  - **Summary bar:** `total_points` + sub-task count; "Does not need a breakdown" badge when `needs_breakdown:false`.
  - **Strategy:** 1–2 sentences.
  - **Warning banner:** shown when `warning` is non-empty.
  - **Sub-task list:** cards with title, story-points badge, order; click/expand → developer description + `depends_on`. Copy buttons (title / whole sub-task / whole breakdown as Jira-pasteable text).
- Loads versions via `task_breakdowns#index` (JSON) and renders JSON → HTML.

### Right panel — chat
Reuses the existing `task_chat_controller.js` SSE flow (or a trimmed variant), pointed at `breakdown_chat_session`. On each `done` carrying a new `<breakdown>`, it emits an event the left panel listens for, then re-renders the latest version.

### Entry point
"AI estimate & breakdown" button in the Details sidebar of `show.html.erb` (next to "AI refined ticket description") → links to `/jira_tasks/:id/breakdown`.

## Error Handling

- **Invalid AI output** (missing marker / bad JSON / out-of-set points): do not persist; show a chat message; AI retries; left panel keeps prior version or shows retry state.
- **Claude CLI failure / timeout:** surfaced in chat (reuse existing SSE error handling); left panel shows retry.
- **No versions yet + generation fails:** left panel shows an empty "Generate" / "Try again" state.

## Testing (Minitest, per CLAUDE.md)

- `<breakdown>` extraction + validation: valid JSON accepted; out-of-Fibonacci points rejected; `needs_breakdown:false` accepted with empty subtasks; malformed JSON rejected.
- `TaskBreakdownsController#show`: latest breakdown present → renders it; absent → signals auto-generate.
- `TaskBreakdownsController#index`: returns only `source:"breakdown"` versions, newest first.
- `ChatStreaming` concern: shared streaming/persist works for both `refine` and `breakdown` purposes.
- `task_drafts` source filtering: refinement modal never receives breakdown rows and vice-versa.

## Open Questions

None — all resolved during brainstorming.
