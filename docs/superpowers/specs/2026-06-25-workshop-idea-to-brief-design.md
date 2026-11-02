# Workshop — Idea → Brief (and Brief → Task relocation)

**Date:** 2026-06-25
**Status:** Approved design, ready for implementation plan

## Summary

A new top-level **Workshop** tab (admin-only, behind a `workshop_enabled`
workspace toggle) that houses two paths:

1. **Idea → Brief** (new — the focus of this spec): a short multi-step pipeline
   that turns a feature idea (new or an existing Jira task) into a versioned,
   concise **brief** through an AI conversation that behaves like a skeptical
   Product Owner, then commits that brief back to Jira and marks the issue
   **"Briefed"**.
2. **Brief → Task** (already exists as the Refine + Breakdown chat system):
   relocated under Workshop and given a new **"Update Jira"** button that writes
   the accepted breakdown back to the Jira issue.

The brief is stored in Gold as the source of truth (versioned); Jira receives
the latest accepted version.

## Context — what already exists (do not rebuild)

- **Jira is read-only today.** `JiraClient` and `JiraSyncService` only pull from
  Jira; there is no write path. This spec adds the first Jira-write capability.
  Auth is global env vars (`JIRA_DOMAIN`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) — writes
  use the same credentials.
- **"Brief to task" already exists** as the Refine + Breakdown feature:
  - `ChatSession` (`purpose: "refine" | "breakdown"`, persistent `claude_session_id`,
    workspace-scoped, soft-archived via `status`).
  - Versioned `TaskDraft` (`source: "ai" | "breakdown"`, `content` markdown/JSON).
  - `ChatStreaming` concern (SSE + persistence machinery).
  - `task_chat` Stimulus controller (streaming chat UI, side-by-side/fullscreen).
  - `BreakdownParser` (validates breakdown JSON, Fibonacci points).
  - Routes nested under `resources :jira_tasks` → `breakdown`, `chat_session`,
    `breakdown_chat_session`, `task_breakdowns`.
- **`ClaudeCliService`**: `start_session(prompt:)` → `{session_id:, response:}`;
  also `send_initial_streaming` / `send_message_streaming` for chat. Codebase path
  defaults to `~/work/elvium`.
- **Sprints exist**: synced `JiraSprint`; tasks carry `sprint_id` / `sprint_name`.
- **Projects have no description/info fields** — both new project fields are net-new.
- **Feature-toggle pattern**: boolean column on workspace, permitted in
  `workspace_settings_params`, checkbox in `workspace_settings/show`, guarded in
  views (`current_workspace.<flag>?`) and controllers (`require_admin!` + flag check).
- **PR reviewer lesson**: never conflate "operation succeeded with nothing to do"
  with "operation failed". Failed Jira writes must surface an error and must NOT
  flip state to "briefed".

## Decisions (locked)

- **Jira write**: build real write methods (create issue, update description, set
  "AI actions" custom field). Uses existing global Jira creds.
- **Idea input**: text only for now (title + description). Voice (browser Web
  Speech API, free) can be bolted onto the same field later; out of scope.
- **Features-summary scope**: per Jira-connected project (each gets its own
  daily-scanned summary), even though the scan reads the single `~/work/elvium` repo.
- **"First prompt" = the manual project-context field.** There is no separate
  editable system prompt. The user edits `context_info`; that is what the AI consumes.
- **Brief storage**: new dedicated `Brief` model, versioned (not a new `TaskDraft`
  source).
- **Existing-task picker**: tasks in the project's **design sprint** (sprint name
  contains "design", case-insensitive).
- **Access**: admin-only, behind a `workshop_enabled` workspace toggle.
- **Daily scan**: ~05:00 Warsaw; `git pull` master first, then scan; failures
  preserve the prior summary.
- **New idea → Jira**: issue is **created** only when a brief is accepted/committed
  (not on idea entry). Existing task → issue is **updated**. "Briefed" is set on
  commit, not on draft.

## Data model

### New models

**`Brief`**
- `belongs_to :task` **(optional)**, `belongs_to :workspace`
- For the **new-idea** path the Jira issue and Gold `Task` do not exist until
  commit, so draft briefs are created with `task_id` null and instead carry the
  in-progress idea (`idea_title`, `idea_body` columns) plus `project_id`. On
  commit, the Task is created and the brief's `task_id` is backfilled. For the
  **existing-task** path `task_id` is set from the start.
- `project_id` (integer, not null) — anchors briefs before a task exists and scopes
  version numbering for new ideas.
- `idea_title` (string, nullable), `idea_body` (text, nullable) — only set on the
  new-idea path before a task exists.
- `version` (integer, increments per task — or per (project, idea) before a task
  exists: `1, 2, 3…`)
- `content` (text, markdown — the concise concept/feature description)
- `status` (string enum: `draft` | `briefed`, default `draft`)
- `briefed_at` (datetime, set when committed to Jira)
- `chat_session_id` (integer, nullable — which conversation produced it)
- timestamps
- Index: unique on `[task_id, version]` (task path) — for the new-idea path
  versions are scoped by a per-idea grouping (e.g. a `workshop_session` id or the
  draft's own root); finalize the exact grouping key in the plan.
- Methods: `Brief.next_version_for(...)`, `mark_briefed!` (sets status + briefed_at).
- `Task#latest_brief` helper (mirrors `latest_draft` / `latest_breakdown`).

**`ChatSession` extension**
- Allow new `purpose: "brief"` (no schema change — `purpose` is a free string today;
  confirm during implementation and add to any validation/enum).

### New columns on `projects`

- `features_summary` (text, nullable) — auto-filled by daily scan.
- `features_summary_updated_at` (datetime, nullable).
- `context_info` (text, nullable) — manual users/architecture/goal; always editable.

### New column on `workspaces`

- `workshop_enabled` (boolean, default false).
- (Possibly) `jira_ai_actions_field_id` (string, nullable) — cached custom-field ID
  for the "AI actions" field, discovered once via the Jira `/field` endpoint. If
  absent, the Jira-write button surfaces a clear "couldn't find the AI actions
  field" error instead of guessing.

## Jira-write capability (`JiraClient`)

New methods (all using the existing global creds, `Net::HTTP`, ADF where required):

- `create_issue(project_key:, summary:, description:, issue_type:)` → returns new key/URL.
- `update_issue_description(key:, description:)`.
- `set_ai_action(key:, value:)` — sets the "AI actions" custom field (multi-select
  checkbox per the screenshot: values include "Briefed", "Details Gathered",
  "Added specification and branch", "Estimated"). Adds the value rather than
  replacing the whole set where the field is multi-value.
- `discover_ai_actions_field_id` — one-time lookup via `GET /rest/api/3/field`,
  matching the field named "AI actions"; cache on workspace.

All write methods return a result object `{ ok: true, ... }` / `{ ok: false, error: }`.
Callers must check it. On `ok: false`: keep Gold state, show inline error, do NOT
mark briefed. (PR-reviewer lesson — no silent success.)

## "Idea → Brief" pipeline flow

Single Turbo-driven page; steps revealed progressively (no separate page loads),
reusing the existing streaming-chat UX.

**Step 1 — Pick the subject**
- Choose **Existing task** or **New idea**.
- *Existing*: list tasks in the project's **design sprint** (sprint name contains
  "design", case-insensitive), showing key + title + Briefed badge. Select one.
- *New*: text fields title + idea description. Held in memory; no Jira issue yet.

**Step 2 — AI conversation (Product Owner)**
- Before the first turn, assemble AI context: project `context_info` (manual),
  project `features_summary` (daily scan), linked Jira ticket (existing path), and
  the idea text (new path).
- AI acts as a skeptical PO: focuses on user value, proposes the best option given
  the existing app, and **challenges business logic only when it makes sense**
  (prompt instructs selective push-back, not reflexive).
- Multi-turn streaming chat — same machinery as Refine/Breakdown (`ChatStreaming`,
  `task_chat`).

**Step 3 — Brief proposal**
- When confident, the AI emits `<brief>…</brief>` → saved as a new `Brief` version
  (`status: draft`). Concise by instruction: the whole concept, describes the
  feature, no padding / no over-long descriptions.
- User can keep chatting to revise; each accepted proposal is a new version. A
  version dropdown shows history (mirrors breakdown version UI).

**Step 4 — Commit to Jira ("Brief & mark Briefed")**
- *New idea* → `create_issue` (description = latest brief), create/link a Gold `Task`.
- *Existing task* → `update_issue_description` with the latest brief.
- Both → `set_ai_action(key:, value: "Briefed")`, then `Brief#mark_briefed!`.
- On any Jira-write failure: inline error, brief stays in Gold, not marked briefed.

## "Brief → Task" relocation

- The existing `/jira_tasks/:id/breakdown` Refine + Breakdown UI keeps working;
  Workshop surfaces/links it as the second path for tasks that are already Briefed.
- **New "Update Jira" button** on the breakdown view: writes the accepted breakdown
  (description + acceptance criteria; optionally the sub-task list) back to the Jira
  issue and sets the matching "AI actions" value (map existing draft sources to the
  field values, e.g. breakdown → "Added specification and branch" / "Estimated").
  Same result-checking / error rules as above.

## Daily features scan — `ProjectFeaturesScanJob`

- Recurring, ~`0 5 * * *` (Warsaw, evaluated in app TZ).
- `git pull` (fast-forward) the `~/work/elvium` checkout to latest `master` first.
- For each Jira-connected project in workspaces with `workshop_enabled`, run
  `ClaudeCliService.start_session` with a "summarize the current features and main
  architecture of this codebase" prompt → store in `features_summary` +
  `features_summary_updated_at`.
- Failures (git pull / CLI error / empty output) **preserve** the prior summary and
  log; never blank the field. Detect CLI auth/quota failures the same way the PR
  reviewer does (don't store an error string as a "summary").

## Navigation & settings

- New top-level **Workshop** sidebar item, admin-only, shown only when
  `current_workspace.workshop_enabled?`.
- `workspace_settings/show` gets a **Workshop** toggle; `workspace_settings_params`
  permits `:workshop_enabled`.
- Project form gains a **Project context** (`context_info`) textarea (always
  editable) and shows the read-only auto-generated **Features summary** with its
  last-updated timestamp.

## Error handling (summary)

- Jira writes return a checked result; failure → inline error, no state flip, brief
  retained. No silent success.
- Missing "AI actions" field ID → clear, specific error; do not guess a field.
- Daily scan failure → keep prior summary, log; never blank.
- AI-conversation errors → reuse existing streaming error handling.

## Testing (Minitest)

- **`Brief` model**: `next_version_for` increments per task; `mark_briefed!` sets
  status + `briefed_at`; `Task#latest_brief`.
- **`JiraClient` writes** (WebMock): `create_issue`, `update_issue_description`,
  `set_ai_action`, `discover_ai_actions_field_id` — success and failure paths;
  failure returns `ok: false` and does not raise.
- **Pipeline controller**: Step-1 existing vs new branch; access control
  (admin-only; toggle off → blocked); a `<brief>` block in a turn creates a new
  `Brief` version; commit path on new idea creates issue + task, existing path
  updates; Jira-write failure does not mark briefed.
- **`ProjectFeaturesScanJob`** (stubbed CLI): success updates field; failure /
  auth-error / empty output preserves prior value.
- **Sidebar**: Workshop link shown for admin with toggle on; hidden for employee
  and when toggle off.

## Out of scope

- Speech-to-text (text only for now).
- Per-project distinct git repos (scan reads the single elvium checkout).
- Writing sub-tasks as separate Jira issues (only the parent issue is written;
  breakdown content goes into the parent unless a later spec says otherwise).
- A separate editable AI system prompt (the manual `context_info` field is the
  only user-editable AI input).

## Setup dependencies

- Discover and cache the Jira **"AI actions"** custom-field ID (via `/rest/api/3/field`).
- Confirm the field's type (multi-select checkbox per the screenshot) and the exact
  option value strings ("Briefed", "Details Gathered", "Added specification and
  branch", "Estimated").
- Confirm the global Jira token has write/edit-issue permission.
