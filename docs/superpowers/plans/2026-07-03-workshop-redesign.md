# Workshop Redesign ("Clar") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Workshop product's UI and feature set to match `redesign.html` (the "Clar" mockup): a new shell (top bar + collapsible sidebar), a Create Tasks idea pipeline with a 3-step AI workspace (Briefing → Details → Ready), Process Optimization (AI PR Reviews / AI Estimate / AI Alerts), Reporting, Bug Reporting, and an admin Configuration area — while leaving the Time & HR product **pixel-for-pixel unchanged**.

**Architecture:** The app already splits into two session-selected "products" (`:time_hr` / `:workshop`) sharing one Rails 8.1 codebase. The redesign adds a second layout (`app/views/layouts/workshop.html.erb`) + a scoped design-token system, new `Workshop::` namespaced controllers for the new screens, and extends the existing AI plumbing (Claude CLI via SSE — `ChatStreaming` + `ClaudeCliService`) and Jira sync rather than replacing them. Existing models (`Brief`, `TaskDraft`, `ChatSession`, `PrReview`, Jira mirror models) are extended; new models are added for alerts, design requests, bug attributions, and Discord webhooks. HR controllers/views/layout branches are never edited (see HR Boundary).

**Tech Stack:** Rails 8.1.3 / Ruby 3.4.1, Hotwire (Turbo + Stimulus, importmap), Tailwind CSS v4 (CSS-first config in `app/assets/tailwind/application.css`), Chart.js 4 (already pinned), SSE streaming via `ActionController::Live`, Claude Code CLI subprocess (`ClaudeCliService`), Solid Queue jobs, Minitest. **Databases: PostgreSQL in development/test, MySQL in production** (`config/database.yml`, `mysql2` gem) — see the portability constraint below.

---

## Global Constraints

- **HR untouched.** No behavioral or visual change to any Time & HR screen. Files in the "HR Boundary — do not touch" list below may not be edited. Shared files (also listed) may only receive *additive* changes that don't alter HR rendering or behavior.
- **`app/views/layouts/application.html.erb` is frozen.** Workshop controllers switch to the new `workshop` layout via `layout "workshop"`; the old layout keeps serving HR (and its now-dead workshop branches are left in place until the final cleanup task, which only removes provably dead code).
- **Design tokens** come verbatim from `redesign.html` lines 23–44 (light `:root` + dark). Prefix: none — they are scoped under `.clar-app[data-clar-theme=…]` so they can't leak into HR. Fonts: **Figtree** (400/500/600/700) body, **JetBrains Mono** (400/500) for Jira keys/branches/tokens/costs — loaded only in the workshop layout.
- **Component classes, not inline styles.** The mockup uses inline styles; we implement everything as `clar-*` component classes in `app/assets/tailwind/application.css` (Phase 1 defines them). Per user preference (memory: feedback_design_direction): no raw inline `style=` color attributes in new views.
- **AI provider stays the Claude CLI** (`ClaudeCliService`); no API SDK is introduced. All new AI outputs use the existing strict-block extraction pattern (`<brief>`, `<draft>`, `<breakdown>` → new: `<alert>`, `<attribution>`, `<estimate>`).
- **Database portability (critical):** dev/test run PostgreSQL but **production runs MySQL**. Every new migration and query must run on both: no `jsonb` (use `:json`; MySQL JSON columns cannot have DB defaults — set defaults in the model with `attribute :col, default: […]`), no `ILIKE` (use `LOWER(col) LIKE LOWER(:q)`), no partial indexes (`add_index …, where:`), no `DISTINCT ON` / `UPDATE … FROM` / window-function SQL (write data backfills in Ruby with `find_each` + `update_columns`, using bare `class X < ActiveRecord::Base; end` stubs inside the migration), no `array_position` (use a SQL `CASE`). The existing schema already follows this (e.g. `tasks.labels` is JSON-in-text).
- **Jira writes remain `JiraWriter`-style**: never raise, return `{ok:, error:}`, only flip local state on success.
- **Roles:** Config area = `require_admin!`. The Create Tasks pipeline relaxes from admin-only to any member with `workshop_access` (mock's "Product Owner"). Clients keep exactly their current access (Jira Tasks board only). Flagged in Open Decisions D1.
- **Copy is taken verbatim from the mockup** (headlines, empty states, helper text, button labels) — quoted in each task.
- **Tests:** Minitest. Every migration-backed model change and every controller action gets a test. System tests optional (no existing system-test infra — do not introduce).
- **Currency:** Reporting displays cost using each project's `currency` (existing `Project::CURRENCIES`), not hardcoded `$`.
- **Timezone:** all scheduling (alerts) uses the app TZ (Warsaw, `config/application.rb:37`).
- **Commits:** one per task minimum, `feat:`/`fix:`/`chore:` prefixes, as in recent history.

---

## Reference A — Complete feature inventory from `redesign.html` (what we're building)

Disposition legend: **NEW** = no equivalent exists · **ADAPT** = exists, needs new UI/UX · **EXTEND** = backend partially exists, needs schema/logic + UI.

### A1. Shell (Phase 1)
| # | Feature | Disposition |
|---|---|---|
| 1 | Top bar: logo "C/Clar", **project switcher** (name + team/client + green dot, dropdown "SWITCH PROJECT · SWAPS EVERYTHING") | ADAPT (`session[:workshop_project_id]` + `_workshop_topbar` exist) |
| 2 | Top bar: per-project **integration status chips** (Jira/GitHub/Discord/Figma, green/gray dot) | NEW |
| 3 | Top bar: **theme toggle** (light/dark, sun/moon icon) | ADAPT (4-theme HR system stays; workshop gets its own 2-theme toggle) |
| 4 | Top bar: user chip (initials avatar, name, role label) | NEW |
| 5 | **Collapsible sidebar** (236px ↔ 64px, chevron, "WORKSPACE" label, icon-only + dot badges when collapsed, state persisted) | NEW |
| 6 | Sidebar nav: **Process Optimization / Create Tasks (badge = active pipeline count) / Reporting / Bug Reporting**; ADMIN section → **Configuration** | NEW |
| 7 | Sidebar footer: **Claude status card** ("Claude Opus", "Repo checked out · master refreshed 2h ago"; collapsed = pulsing dot) | NEW (data from `projects.features_summary_updated_at`) |
| 8 | Light/dark theme, Figtree + JetBrains Mono, full token set, `clarFade`/`clarToast`/`clarBlink` animations, hover classes, custom scrollbar | NEW |
| 9 | Global **toast** component (bottom-center, dark pill, green check, auto-dismiss) | NEW |

### A2. Create Tasks — pipeline landing (Phase 2)
| # | Feature | Disposition |
|---|---|---|
| 10 | H1 "Create Tasks" + intro copy; two entry cards: **New idea** / **Existing Jira task** | ADAPT (exists as `workshop/index` + `new_idea`) |
| 11 | "IN THE PIPELINE" list: rows with LOCAL/`KEY` chip, title, author, created-ago, design badges, **stage badge** (New idea / Briefing / Details Gathering / Ready · in Jira), chevron | EXTEND (needs `tasks.workshop_stage`) |
| 12 | **Search** ("Search tickets…", matches title/id/key/author) + **sort** select (Newest first / Oldest first / Pipeline stage / Title A–Z) | NEW |
| 13 | **Stage filter chips** with counts (All/New/Briefing/Details/Ready) + **source chips** (All sources / In Jira / Local ideas — solid-dark active style) | NEW |
| 14 | Empty state "No tickets match your search or filter." | NEW |
| 15 | Sidebar "Create Tasks" **badge** = count of pipeline ideas not yet ready | NEW |

### A3. Idea intake (Phase 3)
| # | Feature | Disposition |
|---|---|---|
| 16 | **New idea modal**: TITLE\* + DESCRIPTION (optional), "Save & start briefing" (disabled until title), creates local idea at stage briefing, toast `Idea saved · "{title}"` | ADAPT (today: full-page form) |
| 17 | **Browse Jira boards modal**: board tabs (all synced boards + Backlog), sprint label, per-board search "Filter this board…" | NEW (today: flat design-sprint list only) |
| 18 | Kanban view in modal: sticky column headers from synced board columns + counts, cards (title, type dot Story/Task/Bug, mono key, pts pill, assignee avatar, "·" when unassigned), empty col "—" | NEW (reuses `JiraBoard*` mirror + `_kanban` patterns) |
| 19 | **Backlog grooming table**: TYPE chips (All/Story/Task/Bug), SORT (Priority/Story points/Newest/Oldest/Title A–Z), columns KEY/SUMMARY/TYPE/PRIORITY/PTS/REPORTER, priority colors, "No tickets match." | NEW |
| 20 | Click card/row → **import**: idea enters pipeline at briefing, chat seeded "I pulled {KEY} from Jira and read the related code…", toast `Imported {KEY} from Jira` | ADAPT (existing `workshop#start` mode=existing) |

### A4. Idea workspace — shared chrome (Phase 4)
| # | Feature | Disposition |
|---|---|---|
| 21 | Workspace header: "← All tasks", key chip, **inline rename** (pencil → input, Enter/blur saves, toast `Renamed`) | NEW |
| 22 | **3-step stepper** Briefing → Details → Ready (done=green ✓, current=indigo, future=gray; done/current steps clickable) | NEW (stages exist implicitly: brief chat vs refine chat vs done) |
| 23 | Two-panel grid: chat left, document right (460px); **panel size modes** normal ↔ focus (document full-screen, chat hidden) | ADAPT (task_chat has sideBySide/fullscreen states) |
| 24 | Persona banner: "Briefing · acts like a Product Owner" / "Details Gathering · senior partner" + "Reads project & task description first" | NEW |
| 25 | **Reset session** modal ("AI re-reads the code. All saved versions and the description are kept", shows KEPT description box) + footer **Reset chat** (lighter reset, keeps current version as base) | ADAPT (destroy-session exists; two-tier semantics NEW) |
| 26 | Chat: AI/user bubbles, typing dots, Enter-to-send textarea, auto-scroll | ADAPT (exists in `task_chat_controller.js`) |

### A5. Document versions panel (Phase 4–5)
| # | Feature | Disposition |
|---|---|---|
| 27 | Version chips v0…vn; **selected vs current** (green dot = current); source badges (USER DESCRIPTION / AI drafted / Manual edit / User description (edited)); CURRENT / IN JIRA / SAVED LOCALLY badges | EXTEND (`Brief.version` exists; current-pointer, sources NEW) |
| 28 | v0 = seeded from existing Jira/local description; empty state shows current Jira description + AI explainer box | NEW |
| 29 | **Rich-text editing** (contenteditable): toolbar Bold/Italic/bullets/numbered/H/¶/code/link; **Save v{n} in place** vs **Save as new version**; Cancel | NEW |
| 30 | **Set v{n} as current** → updates local desc or Jira description text, toast | NEW |
| 31 | **Save locally** (finish without Jira; details stage → Ready with LOCAL badge) | EXTEND (briefs are local-only until commit today) |
| 32 | **Push to Jira**: briefing → "Brief & mark Briefed" (creates issue for local ideas, sets AI actions=Briefed, advance to Details); details → "Update Jira description"/"Push to Jira" (sets AI actions=Detailed, advance to Ready) | ADAPT (`JiraWriter#commit_brief` exists; "Detailed" action value NEW) |
| 33 | **Brief history modal** in details stage (version chips, rendered brief, "Back to briefing to improve") | NEW |
| 34 | AI auto-drafts document at end of Q&A (one "AI drafted" version per conversation round), toast "AI drafted the brief/description · now current" | ADAPT (block extraction exists) |

### A6. Designs flow (Phase 5)
| # | Feature | Disposition |
|---|---|---|
| 35 | Designs strip (details+ready): "Optional · the designer prepares these…", states none → **Requested from {designer} · pending** → **{n} link(s) in Jira description · by {designer}**; buttons Request from designer / Mark delivered / Cancel / Request changes | NEW |
| 36 | **Request designs modal**: designer picker (workspace members), NOTE optional, toast `Design request sent to {name}` | NEW |
| 37 | Figma link rows (name + mono URL + IN DESCRIPTION badge + remove); delivery appends links to Jira description | NEW |
| 38 | Pipeline badges "Designs requested" (amber) / "Designs ready" (green) | NEW |

### A7. Ready screen (Phase 5)
| # | Feature | Disposition |
|---|---|---|
| 39 | Success layout "Ready for the team" + summary card: key/title/IN JIRA-or-LOCAL badge; grid AI actions=Detailed · AI estimation (pts, `· auto`) · Designs · Versions saved | NEW (estimate from breakdown/estimation, §A9) |
| 40 | "AI prepared a branch" card: branch `feat/{key-}{slug}`, **Copy** copies `git checkout {branch}`, explainer copy | NEW (display + clipboard only — no server-side git) |
| 41 | Push to Jira (if still local) + Back to pipeline | NEW |

### A8. Process Optimization — AI PR Reviews tab (Phase 6)
| # | Feature | Disposition |
|---|---|---|
| 42 | Stats trio: reviewed today / with comments / looks good | EXTEND (`pr_reviews` lacks outcome metadata) |
| 43 | Polling chip "Polling every {n} min · last {x} ago" | EXTEND (interval configurable, §A11) |
| 44 | PR feed: #num, title, author · mono branch · time-ago, outcome pill "Looks good!" / "{n} comments", GitHub ↗ link | EXTEND |
| 45 | Disclaimer "The AI never approves or merges — a human still issues the GitHub approval." | NEW (true today: `event: COMMENT`) |

### A9. Process Optimization — AI Estimate tab (Phase 6)
| # | Feature | Disposition |
|---|---|---|
| 46 | ESTIMATION TARGET summary card (Board, "Estimate when", "Writes to field(s)" chips, "Manual estimate fields are never touched.") | NEW |
| 47 | Estimates table TASK/TITLE/AI EST./MANUAL (manual `—` when absent) | EXTEND (needs story-points sync + `tasks.ai_estimate_points`) |
| 48 | **Auto-estimation engine**: triggers — Added to a Development sprint / Status changes to "Ready for dev" / AI actions = Briefed / Manually, on request; writes chosen Jira field(s) | NEW |

### A10. Process Optimization — AI Alerts tab (Phase 6)
| # | Feature | Disposition |
|---|---|---|
| 49 | Rules list: name, last-result chip (Sent · … / No condition met / Not run yet), italic quoted prompt, schedule, `{channel} · Discord`, last run, "View history" | NEW |
| 50 | **New alert rule modal**: NAME\*, WHAT TO WATCH FOR\* (natural-language condition), FREQUENCY (Daily/Weekdays/Mon, Wed, Fri/Weekly (Mon)/Every hour), TIME (disabled for hourly), NOTIFY CHANNEL chips | NEW |
| 51 | **Alert history modal**: "Fired {x} of {y} runs", run timeline (NOTIFIED/NO ACTION, summary, detail, timestamp) | NEW |
| 52 | Scheduled execution: AI inspects live Jira state on schedule, posts to Discord channel only when condition met | NEW (`AlertRule`/`AlertRun` + dispatch job; board snapshot fed to CLI — no Jira MCP needed) |

### A11. Reporting (Phase 7)
| # | Feature | Disposition |
|---|---|---|
| 53 | Header controls: **developer scope** select (All team / each dev, avatar) + period toggle (current month / active sprint) | NEW |
| 54 | 5 metric cards: Features delivered (+pts merged) / Completed story points / New bugs / Hours worked ("from time-tracking") / Project cost (month to date) | NEW (hours+cost read from HR `time_entries` — read-only) |
| 55 | **Story points delivered over time** chart: Months/Sprints granularity, ranges 6m/1y/2y or 8/13/26 sprints, delta badge "+N vs start", hover tooltip | NEW (Chart.js; needs done-issue + story-point sync) |
| 56 | **Per-developer results** table: SP done / bugs fixed / bugs created / hours / cost + Team total row; "Hours & cost from internal time-tracking" | NEW |
| 57 | **Delivered this period** table: KEY/FEATURE/DELIVERED BY/PTS/PRS/MERGED + "{n} features shipped · {pts} pts" | NEW (PRS count via `PrJiraKey` match on `pr_reviews`) |

### A12. Bug Reporting (Phase 8)
| # | Feature | Disposition |
|---|---|---|
| 58 | Stat cards: Bugs created · {month} / Created the most / Fixed the most | NEW |
| 59 | **Bugs over time** chart (created vs fixed, legend, same granularity/range controls, inverted delta colors) | NEW |
| 60 | **Bug analysis** list: key, title, origin badge (New functionality / Existing code), attribution badge "{author} · High confidence/Medium/Likely:", AI reasoning box (git-blame evidence) | NEW (`BugAttribution` + CLI job) |

### A13. Configuration (Phase 9) — admin only
| # | Feature | Disposition |
|---|---|---|
| 61 | "ADMINISTRATOR ONLY" badge; tabs Integrations / AI / Users | NEW |
| 62 | Integration cards GitHub / Jira Cloud / Discord / Figma with status + detail line + **Manage** modals (fields per mockup: repo/token/branch + toggles; site URL/project key/custom fields/MCP toggle; webhook list + add/remove + Slack/Teams SOON; Figma token/team + toggle) — Test connection / Save | EXTEND (GitHub per-workspace exists; Jira is ENV → read-only display; Discord webhooks NEW) |
| 63 | AI tab: provider card (Claude Opus · active, read-only), **PR review prompt** textarea (persisted, used by PrReviewJob), **PR polling interval** slider 1–30 min (honored by check job), **Estimation target** (field chips ≥1 + trigger radio) | NEW |
| 64 | Users tab: member list (avatar/name/email/role badge) + Invite | ADAPT (reuses `workspace_members` data; UI read-mostly, links to existing invite) |

### A14. Cross-cutting behaviors
| # | Feature | Disposition |
|---|---|---|
| 65 | Toasts for every action (exact copy in tasks) | NEW |
| 66 | Idea state machine: `new → briefing → details → ready`; design sub-state `none → requested → delivered`; pushed flags; LOCAL vs Jira-linked | NEW (`tasks.workshop_stage` et al.) |
| 67 | "Claude Opus" status = CLI-driven; repo freshness from features-scan job | ADAPT |

Mock quirks deliberately **not** implemented (or adapted): `panelSize === 'wide'` (unreachable in mock); fake `SP-1042` default key on push (we use the real created issue key); demo-data numbers; the unreachable `DRAFT · NAME TO SAVE` badge (our new-idea modal always requires a title, so drafts can't exist); the mock's share-scaling of the dev-focused trend chart (we filter real per-developer data instead — an improvement, noted in Task 7.1); all **"via MCP"** copy — alerts read a live board *snapshot*, not MCP, so: the new-rule modal intro becomes "…the AI inspects the live Jira board state and posts to the channel only if the condition is met.", the Jira integration card drops "· MCP enabled" (replacement: "· AI fields verified"), and the Jira manage modal's "MCP access for AI Alerts" toggle is omitted.

---

## Reference B — Current-state anchor points (verified file paths)

- Products & gating: `app/controllers/concerns/workspace_scoped.rb` (`current_product`, `product_landing_path`, `current_workshop_project`, `workshop_projects`), `app/controllers/concerns/authorization.rb` (`require_admin!`, `require_product!`, `visible_jira_projects`), `app/models/user.rb` (product accessors).
- Workshop today: `app/controllers/workshop_controller.rb` (landing/new_idea/start/brief), `app/views/workshop/*`, `app/views/jira_tasks/*` (board, task page, chat panel), `app/views/task_breakdowns/show.html.erb`.
- AI chat: `app/controllers/concerns/chat_streaming.rb` (SSE core), `app/services/claude_cli_service.rb`, purposes: refine (`chat_sessions_controller.rb`), breakdown (`breakdown_chat_sessions_controller.rb`), brief (`brief_chat_sessions_controller.rb`); extraction into `TaskDraft` (source `ai`/`breakdown`) and `Brief` (versioned, draft→briefed).
- Jira: `app/services/jira_client.rb` (ENV creds), `jira_sync_service.rb` (15-min `JiraSyncJob`; open issues only), `jira_writer.rb` (`commit_brief`, `commit_breakdown`, "AI actions" field), mirror models `jira_board*`, `jira_sprint`, `jira_comment`.
- PR review: `app/jobs/pr_review_check_job.rb` (every 7 min, claims), `pr_review_job.rb` (prompt heredoc, ≤4/2 comments, posts `COMMENT` review), `app/models/pr_review.rb`, `app/services/github_client.rb`, `pr_jira_key.rb`.
- Discord: `app/services/discord_group_client.rb` (user-token group DM — reminders only).
- Frontend: Tailwind v4 CSS-first at `app/assets/tailwind/application.css` (1,976 lines, `m3-*` system, 4 themes via `:root[data-theme]`); 35 Stimulus controllers in `app/javascript/controllers/` (37 files incl. application.js/index.js); Chart.js + flatpickr pinned in `config/importmap.rb`; DaisyUI in package.json but unused.
- Jobs schedule: `config/recurring.yml` (jira_sync 15m, pr_review_check 7m 9–19h, features scan 05:00, discord 11:00, holiday grant Jan 1).
- Schema (v 2026_06_26_000001): `briefs`, `task_drafts`, `chat_sessions/messages`, `pr_reviews`, `jira_*`, `tasks` (no story points, no jira_created_at/resolved_at), `workspaces` flags.

## Reference C — HR Boundary

**Do not touch (HR-owned):** `app/controllers/{time_entries,timers,timesheets,tags,holiday_requests,holiday_balance_entries,feedback_meetings,clients,projects,project_memberships,workspace_members,workspace_settings,discord_reminder_recipients,profiles,dashboard,home,sessions,passwords,registrations,workspaces}_controller.rb`, `app/controllers/reports/**`, all their views under `app/views/{time_entries,timers,timesheets,tags,holiday_requests,holiday_balance_entries,feedback_meetings,clients,projects,workspace_members,workspace_settings,profiles,reports,sessions,passwords,registrations,workspaces,dashboard,shared}/**`, `app/views/shared/_timer_bar.html.erb`, HR Stimulus controllers (`timer*`, `manual_entry`, `timesheet*`, `bulk_select`, `business_days`, `day_timer`, `tag_selector`, `date_presets`, etc.), HR mailers, `app/views/layouts/application.html.erb`, `app/views/layouts/_product_switcher.html.erb` (still rendered by the new layout, unchanged).

**Shared files — additive edits only (each edit is itemized in a task):** `config/routes.rb`, `config/importmap.rb`, `config/recurring.yml`, `app/assets/tailwind/application.css` (append `clar-*` section only; never modify `m3-*`/theme blocks), `app/models/{task,project,workspace,user}.rb` (new methods/associations only), `db/schema.rb` via migrations, `app/services/{jira_client,jira_sync_service,jira_writer}.rb` (new methods + new sync fields), `app/jobs/pr_review_check_job.rb`/`pr_review_job.rb` (read new settings/metadata), `app/controllers/concerns/{workspace_scoped,authorization,chat_streaming}.rb` (new helpers only).

**Explicitly kept working:** HR timer-bar Jira task search (`jira_task_search_controller.js` + `JiraController#jira_tasks`), Project form's Jira-connect + `context_info` fields (`app/views/projects/_form.html.erb`), Workspace Settings toggles, Reports' Jira counts. Jira Tasks board (`/jira_tasks`) stays available (clients depend on it) — it gets the new shell but its inner views are only re-skinned in the final phase (Task 10.2), not restructured.

---

# PHASE 1 — Design system & Workshop shell

### Task 1.1: Clar design tokens + component CSS

**Files:**
- Modify: `app/assets/tailwind/application.css` (append new section at end of file)
- Test: visual (no Ruby test); `bin/rails tailwindcss:build` must compile.

**Interfaces:**
- Produces: CSS classes used by all later views: `clar-app`, `clar-topbar`, `clar-sidebar`, `clar-nav-item[-active]`, `clar-card`, `clar-row`, `clar-chip[-active]`, `clar-chip-dark-active` (inactive source chips are plain `clar-chip`), `clar-badge` (+ `-primary -success -warn -danger -ai -muted`), `clar-btn` (+ `-primary -ai -danger`; the plain `clar-btn` IS the secondary style), `clar-input`, `clar-select`, `clar-textarea`, `clar-tabs`/`clar-tab[-active]`, `clar-modal-overlay`, `clar-modal`, `clar-toast`, `clar-metric`, `clar-table-head`, `clar-key` (mono key chip), `clar-avatar`, `clar-prose`, `clar-editor`, `clar-toggle`, `clar-dot`, `clar-fade` utility, animations `clar-fade`, `clar-toast-in`, `clar-blink`.

- [ ] **Step 1: Append the Clar token + component block** to `app/assets/tailwind/application.css` (after the last existing rule; do not edit anything above). Tokens copied from redesign.html:

```css
/* ============================================================
   CLAR — Workshop redesign design system. Scoped under .clar-app.
   Do NOT use m3-* classes inside .clar-app, or clar-* outside it.
   ============================================================ */
.clar-app {
  --bg:#f6f7f9; --surface:#ffffff; --surface-2:#f1f3f5; --border:#e6e8ec;
  --text:#1a1d24; --muted:#6b7280; --faint:#9aa3af;
  --primary:#4f46e5; --primary-soft:#eef2ff; --primary-2:#4338ca;
  --success:#16a34a; --success-soft:#ecfdf3;
  --warn:#d97706; --warn-soft:#fffbeb;
  --danger:#dc2626; --danger-soft:#fef2f2;
  --ai:#7c3aed; --ai-soft:#f5f3ff;
  --shadow:0 1px 2px rgba(16,24,40,.05),0 1px 3px rgba(16,24,40,.04);
  --shadow-lg:0 8px 28px rgba(16,24,40,.12);
  font-family:Figtree,system-ui,sans-serif;
  background:var(--bg); color:var(--text);
}
.clar-app[data-clar-theme="dark"] {
  --bg:#0e1014; --surface:#161a20; --surface-2:#1d222a; --border:#272d36;
  --text:#e7eaef; --muted:#9aa3b2; --faint:#6b7480;
  --primary:#6366f1; --primary-soft:#1f2138; --primary-2:#818cf8;
  --success:#22c55e; --success-soft:#10241a;
  --warn:#f59e0b; --warn-soft:#2a210f;
  --danger:#ef4444; --danger-soft:#2a1414;
  --ai:#a78bfa; --ai-soft:#1c1830;
  --shadow:0 1px 2px rgba(0,0,0,.4);
  --shadow-lg:0 12px 36px rgba(0,0,0,.5);
}
.clar-mono { font-family:'JetBrains Mono',monospace; }

@keyframes clar-fade { from{opacity:0;transform:translateY(6px)} to{opacity:1;transform:none} }
@keyframes clar-toast-in { from{opacity:0;transform:translate(-50%,12px)} to{opacity:1;transform:translate(-50%,0)} }
@keyframes clar-blink { 0%,80%,100%{opacity:.25} 40%{opacity:1} }

/* Shell */
.clar-topbar { height:56px; flex:0 0 56px; display:flex; align-items:center; gap:18px;
  padding:0 18px; background:var(--surface); border-bottom:1px solid var(--border);
  position:relative; z-index:40; }
.clar-logo { width:26px; height:26px; border-radius:7px; background:var(--primary);
  display:flex; align-items:center; justify-content:center; color:#fff; font-weight:700; font-size:15px; }
.clar-sidebar { width:236px; flex:0 0 236px; background:var(--surface);
  border-right:1px solid var(--border); padding:14px 12px; display:flex;
  flex-direction:column; gap:3px; transition:width .16s ease; }
.clar-sidebar[data-collapsed="true"] { width:64px; flex-basis:64px; padding:14px 10px; }
.clar-nav-item { display:flex; align-items:center; gap:11px; width:100%; padding:9px 10px;
  border-radius:9px; border:none; cursor:pointer; font-size:13.5px; font-weight:500;
  background:transparent; color:var(--muted); text-decoration:none; }
.clar-nav-item:hover { background:var(--surface-2); }
.clar-nav-item-active { background:var(--primary-soft); color:var(--primary); font-weight:650; }
.clar-nav-label { font-size:10.5px; font-weight:700; letter-spacing:.7px; color:var(--faint); padding:6px 10px 8px; }
.clar-nav-badge { font-size:10.5px; font-weight:700; background:var(--primary); color:#fff;
  border-radius:20px; padding:1px 7px; }
.clar-status-card { margin-top:8px; padding:12px; border-radius:10px; background:var(--ai-soft);
  border:1px solid var(--border); }

/* Surfaces */
.clar-card { background:var(--surface); border:1px solid var(--border); border-radius:14px; }
.clar-card-hover { transition:border-color .12s, box-shadow .12s; }
.clar-card-hover:hover { border-color:var(--primary); box-shadow:var(--shadow-lg); }
.clar-row { background:var(--surface); border:1px solid var(--border); border-radius:12px; }
.clar-row-hover:hover { border-color:var(--primary); }
.clar-modal-overlay { position:fixed; inset:0; z-index:55; background:rgba(10,12,16,.45);
  display:flex; align-items:center; justify-content:center; padding:24px; animation:clar-fade .12s ease; }
.clar-modal { width:100%; background:var(--surface); border:1px solid var(--border);
  border-radius:16px; box-shadow:var(--shadow-lg); }
.clar-toast { position:fixed; bottom:26px; left:50%; transform:translateX(-50%); z-index:60;
  background:var(--text); color:var(--bg); padding:12px 18px; border-radius:11px;
  box-shadow:var(--shadow-lg); display:flex; align-items:center; gap:10px;
  font-size:13px; font-weight:600; animation:clar-toast-in .2s ease; }

/* Controls */
.clar-btn { display:inline-flex; align-items:center; justify-content:center; gap:7px;
  font-family:inherit; font-weight:600; font-size:13px; border-radius:9px; padding:9px 16px;
  border:1px solid var(--border); background:var(--surface); color:var(--text); cursor:pointer; }
.clar-btn-primary { background:var(--primary); border-color:transparent; color:#fff; font-weight:650; }
.clar-btn-ai { background:var(--ai); border-color:transparent; color:#fff; font-weight:650; }
.clar-btn-danger { color:var(--danger); background:var(--danger-soft); }
.clar-btn:disabled { background:var(--surface-2); color:var(--faint); cursor:not-allowed; border-color:transparent; }
.clar-btn-block { width:100%; padding:12px; border-radius:10px; font-size:13.5px; }
.clar-input, .clar-select, .clar-textarea { font-family:inherit; font-size:13.5px; color:var(--text);
  background:var(--bg); border:1px solid var(--border); border-radius:10px; padding:10px 13px;
  outline:none; width:100%; }
.clar-input:focus, .clar-textarea:focus { border-color:var(--primary); }
.clar-field-label { display:block; font-size:11.5px; font-weight:700; color:var(--faint); margin-bottom:6px; }
.clar-tabs { display:flex; gap:4px; background:var(--surface-2); border:1px solid var(--border);
  border-radius:11px; padding:4px; width:fit-content; }
.clar-tab { font-size:13px; font-weight:600; padding:7px 15px; border-radius:8px; border:none;
  cursor:pointer; background:transparent; color:var(--muted); }
.clar-tab-active { background:var(--surface); color:var(--text); box-shadow:var(--shadow); }
.clar-chip { display:inline-flex; align-items:center; gap:5px; font-size:12px; font-weight:600;
  padding:5px 11px; border-radius:20px; cursor:pointer; border:1px solid var(--border);
  background:var(--surface); color:var(--muted); }
.clar-chip-active { border-color:var(--primary); background:var(--primary-soft); color:var(--primary); }
.clar-chip-dark-active { border-color:var(--text); background:var(--text); color:var(--bg); }
.clar-fade { animation:clar-fade .12s ease; }
.clar-toggle { width:40px; height:23px; border-radius:20px; border:none; cursor:pointer;
  position:relative; flex:0 0 40px; background:var(--border); transition:background .15s; }
.clar-toggle[aria-checked="true"] { background:var(--primary); }
.clar-toggle .knob { position:absolute; top:2px; left:2px; width:19px; height:19px; border-radius:50%;
  background:#fff; transition:left .15s; box-shadow:0 1px 2px rgba(0,0,0,.2); }
.clar-toggle[aria-checked="true"] .knob { left:19px; }

/* Data display */
.clar-badge { display:inline-flex; align-items:center; gap:4px; font-size:11px; font-weight:700;
  padding:3px 9px; border-radius:7px; white-space:nowrap; }
.clar-badge-primary { color:var(--primary); background:var(--primary-soft); }
.clar-badge-success { color:var(--success); background:var(--success-soft); }
.clar-badge-warn    { color:var(--warn); background:var(--warn-soft); }
.clar-badge-danger  { color:var(--danger); background:var(--danger-soft); }
.clar-badge-ai      { color:var(--ai); background:var(--ai-soft); }
.clar-badge-muted   { color:var(--muted); background:var(--surface-2); border:1px solid var(--border); }
.clar-key { font-family:'JetBrains Mono',monospace; font-size:11px; font-weight:600;
  color:var(--primary); background:var(--primary-soft); padding:1px 6px; border-radius:5px; }
.clar-avatar { border-radius:50%; color:#fff; display:inline-flex; align-items:center;
  justify-content:center; font-weight:700; }
.clar-dot { width:7px; height:7px; border-radius:50%; display:inline-block; }
.clar-metric { padding:18px; }
.clar-metric .label { font-size:12px; color:var(--faint); margin-bottom:8px; }
.clar-metric .value { font-size:28px; font-weight:700; letter-spacing:-.5px; }
.clar-metric .sub { font-size:11.5px; color:var(--faint); margin-top:5px; }
.clar-table-head { display:flex; padding:11px 20px; font-size:11px; font-weight:700;
  letter-spacing:.3px; color:var(--faint); border-bottom:1px solid var(--border); }
.clar-h1 { margin:0; font-size:25px; font-weight:700; letter-spacing:-.5px; color:var(--text); }
.clar-sub { margin:7px 0 22px; color:var(--muted); font-size:14px; line-height:1.5; }
.clar-section-label { font-size:13px; font-weight:700; letter-spacing:.4px; color:var(--faint); }

/* Chat + prose (ported semantics from mockup) */
.clar-bubble-ai { background:var(--ai-soft); border:1px solid var(--border); border-radius:13px;
  border-top-left-radius:4px; padding:11px 14px; font-size:13.5px; line-height:1.55;
  color:var(--text); max-width:78%; }
.clar-bubble-user { background:var(--primary); color:#fff; border-radius:13px;
  border-top-right-radius:4px; padding:11px 14px; font-size:13.5px; line-height:1.55; max-width:78%; }
.clar-prose h4 { font-size:11px; font-weight:700; letter-spacing:.4px; color:var(--ai);
  margin:15px 0 4px; text-transform:uppercase; }
.clar-prose > h4:first-child { margin-top:0; }
.clar-prose p { font-size:13px; line-height:1.6; color:var(--text); margin:3px 0; }
.clar-prose ul, .clar-prose ol { margin:5px 0; padding-left:20px; }
.clar-prose li { font-size:13px; line-height:1.6; color:var(--text); }
.clar-prose pre { font-family:'JetBrains Mono',monospace; font-size:12px; background:var(--surface-2);
  border:1px solid var(--border); border-radius:8px; padding:9px 11px; margin:5px 0; white-space:pre-wrap; }
.clar-prose a { color:var(--primary); }
.clar-editor { outline:none; min-height:240px; padding:12px 14px; background:var(--bg);
  border:1px solid var(--border); border-radius:10px; }
.clar-editor:focus { border-color:var(--primary); }
.clar-app ::-webkit-scrollbar { width:10px; height:10px; }
.clar-app ::-webkit-scrollbar-thumb { background:var(--border); border-radius:8px;
  border:2px solid transparent; background-clip:padding-box; }
```

- [ ] **Step 2: Build CSS** — Run: `bin/rails tailwindcss:build`. Expected: compiles with no errors; grep the output for `clar-topbar` to confirm inclusion.
- [ ] **Step 3: Verify HR untouched** — `git diff app/assets/tailwind/application.css` shows only the appended block (no changes above the marker comment).
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: Clar design tokens + component classes for Workshop redesign"`

### Task 1.2: Workshop layout, top bar, sidebar, theme + toast Stimulus controllers

**Files:**
- Create: `app/views/layouts/workshop.html.erb`
- Create: `app/views/layouts/_clar_topbar.html.erb`, `app/views/layouts/_clar_sidebar.html.erb`
- Create: `app/javascript/controllers/clar_theme_controller.js`, `app/javascript/controllers/clar_sidebar_controller.js`, `app/javascript/controllers/clar_toast_controller.js`, `app/javascript/controllers/clar_dropdown_controller.js`, `app/javascript/controllers/clar_modal_controller.js`
- Create: `app/helpers/clar_helper.rb`
- Modify: `app/controllers/workshop_controller.rb`, `app/controllers/jira_tasks_controller.rb`, `app/controllers/task_breakdowns_controller.rb` (+ later new Workshop:: controllers): add `layout "workshop"`
- Test: `test/controllers/workshop_layout_test.rb`

**Interfaces:**
- Produces: layout with `yield`, `content_for :clar_full_bleed` (workspace uses edge-to-edge), helpers `clar_initials(name)`, `clar_avatar_color(seed)` (deterministic palette pick from `%w[#4f46e5 #0d9488 #db2777 #d97706 #7c3aed]`), `clar_time_ago(t)` ("4 min ago"/"2h ago"/"3d ago"), `clar_toast(msg)` (flash-based). JS event `clar:toast` (`detail: {message}`) that any controller can dispatch.
- Consumes: `current_workshop_project`, `workshop_projects`, `Current.workspace`, `current_user`, existing `switch_workshop_project_path`.

- [ ] **Step 1: Write the failing test** `test/controllers/workshop_layout_test.rb`:

```ruby
require "test_helper"

class WorkshopLayoutTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true) # fixture default is false — required by require_workshop!
    sign_in_as(users(:one)) # admin/owner fixture (there is no users(:admin))
    post switch_product_path, params: { product: "workshop" }
  end

  test "workshop landing renders the Clar shell, not the HR shell" do
    get workshop_path
    assert_response :success
    assert_select "div.clar-app"
    assert_select "header.clar-topbar"
    assert_select "nav.clar-sidebar"
    assert_select "header.m3-top-bar", count: 0
  end

  test "HR pages still render the M3 shell" do
    post switch_product_path, params: { product: "time_hr" }
    get time_entries_path
    assert_response :success
    assert_select "header.m3-top-bar"
    assert_select "div.clar-app", count: 0
  end

  test "clients get the Clar shell on the board but only the Jira Tasks nav item" do
    sign_in_as(users(:client_user))
    get jira_tasks_path
    assert_response :success
    assert_select "nav.clar-sidebar" do
      assert_select "a", text: /Create Tasks/, count: 0
      assert_select "a", text: /Configuration/, count: 0
    end
  end
end
```
(`sign_in_as` already exists in `test/test_helpers/session_test_helper.rb`. Fixtures: `users(:one)` is the admin/owner with `workshop_access: true`; `users(:client_user)` is the client. All new workshop-side integration tests MUST set `workshop_enabled: true` in setup — existing `workshop_controller_test.rb` does the same.)

- [ ] **Step 2: Run it** — `bin/rails test test/controllers/workshop_layout_test.rb`. Expected: FAIL (no `.clar-app`).
- [ ] **Step 3: Create the layout** `app/views/layouts/workshop.html.erb` — structure (full HTML doc mirroring `application.html.erb`'s `<head>` asset tags, but):
  - `<head>`: title "Clar", Google Fonts `Figtree:wght@400;500;600;700` + `JetBrains+Mono:wght@400;500`, FOUC script reading `localStorage.clarTheme` → sets `data-clar-theme` on a marker; keep `stylesheet_link_tag "tailwind"` + importmap tags. Do **not** load flatpickr.
  - `<body>`: `<div class="clar-app flex flex-col h-screen overflow-hidden" data-controller="clar-theme clar-toast" data-clar-theme="light">`
    - `render "layouts/clar_topbar"`
    - `<div class="flex flex-1 min-h-0">` → `render "layouts/clar_sidebar"` + `<main class="flex-1 min-w-0 overflow-y-auto">` with inner `max-w-[1120px] mx-auto px-8 py-7` wrapper unless `content_for?(:clar_full_bleed)` → `<%= yield %>`.
    - Toast element: `<div data-clar-toast-target="toast" class="clar-toast hidden"><span class="check">…svg…</span><span data-clar-toast-target="message"></span></div>`; render `flash[:clar_toast]` into a `data-clar-toast-initial-value`.
- [ ] **Step 4: Top bar partial** `_clar_topbar.html.erb`: logo tile "C" + "Clar"; project switcher `data-controller="clar-dropdown"` — button shows green `clar-dot`, `current_workshop_project&.name`, client name as the small "team" label, chevron; dropdown panel lists `workshop_projects` as `button_to switch_workshop_project_path` rows (name + client · external_reference), header "SWITCH PROJECT · SWAPS EVERYTHING", check icon on the active one. `ProductsController#switch_project` additionally sets `flash[:clar_toast] = "Switched to #{project.name}"` (additive — HR never reads this flash key). Integration chips (Jira / GitHub / Discord / Figma): green/gray dot per: `current_workshop_project&.jira_connected?`, `Current.workspace.github_repo.present? && Current.workspace.github_status_ok`, `Current.workspace.discord_webhooks.exists?` (Phase 6 model — until then `Current.workspace.discord_channel_id.present?`), Figma = `true` when the workspace flag `figma_read_enabled` (Phase 9; until then render gray). Right side: theme toggle button (`data-action="clar-theme#toggle"`, sun/moon SVG swap), user chip (`clar-avatar` 32px with `clar_initials(current_user.name)`, name, role label `current_user.admin_or_owner?(Current.workspace) ? "Administrator" : "Product Owner"` — reuse the exact role-helper API found in `app/models/user.rb`).
- [ ] **Step 5: Sidebar partial** `_clar_sidebar.html.erb` (`data-controller="clar-sidebar"`, `data-collapsed` from localStorage): "WORKSPACE" label + collapse chevron; nav items (SVG icons pasted from redesign.html `NAV` const): **Process Optimization** → `workshop_process_path`, **Create Tasks** → `workshop_pipeline_path` (badge: `@pipeline_badge_count` set by a `before_action` in `Workshop::BaseController`, Task 2.3), **Reporting** → `workshop_reporting_path`, **Bug Reporting** → `workshop_bugs_path`; spacer; "ADMIN" label + **Configuration** → `workshop_configuration_path` (admins only); Claude status card: "Claude Opus" + "Repo checked out · <b>master</b> refreshed {clar_time_ago(current_workshop_project&.features_summary_updated_at)}" (fallback "not yet scanned"); collapsed variant = pulsing `clar-dot` with title tooltip. Also keep a small **Jira Tasks** nav item (board icon) → `jira_tasks_path` under the workspace section (mock omits it, but clients and the breakdown flow live there — Open Decision D2). Active state: compare `request.path` prefix. **Client gating:** when `current_user` is a client in `Current.workspace`, render ONLY the Jira Tasks item — no Process/Create/Reporting/Bugs links, no ADMIN section, no Claude status card (every other link would just bounce clients back via `redirect_clients_to_jira`).
  Until the Phase 2/6/7/8/9 routes exist, point not-yet-built items at `workshop_path` behind `defined?` guards — each later phase's task flips its own item; the sidebar is written once with all five entries and the routes land in the same commit as each screen (acceptable interim: guard with `if respond_to?(:workshop_process_path)`).
- [ ] **Step 6: Stimulus controllers.**
  - `clar_theme_controller.js`: `toggle()` flips `data-clar-theme` on `this.element`, writes `localStorage.clarTheme`, swaps icon targets.
  - `clar_sidebar_controller.js`: `toggle()` flips `data-collapsed`, persists `localStorage.clarSidebarCollapsed`, hides labels via CSS attribute selector already in Task 1.1.
  - `clar_toast_controller.js`: `show(message)`; listens for `clar:toast` on `window` (`connect()` adds listener; `disconnect()` removes); shows toast, clears previous timeout, hides after 2600 ms; on `connect`, if `initialValue` present → show it (server flash).
  - `clar_dropdown_controller.js`: open/close panel target, close on outside click + Escape.
  - `clar_modal_controller.js`: generic `open(event)`/`close()`, backdrop click closes, `stopPropagation` on panel, Escape closes, body scroll lock (this replaces per-feature modal wiring later).
- [ ] **Step 7: Helper** `app/helpers/clar_helper.rb` with `clar_initials`, `clar_avatar_color`, `clar_time_ago`, `clar_toast(message)` (sets `flash[:clar_toast]`).
- [ ] **Step 8: Point workshop-side controllers at the layout** — add `layout "workshop"` to `WorkshopController`, `JiraTasksController`, `TaskBreakdownsController`. (Chat/draft controllers are JSON/SSE only — no layout needed.)
- [ ] **Step 9: Run tests** — `bin/rails test test/controllers/workshop_layout_test.rb`. Expected: PASS. Manually boot `bin/dev`, switch product → Workshop, verify shell, theme toggle, collapse, project switcher.
- [ ] **Step 10: Commit** — `git commit -m "feat: Clar workshop layout — topbar, collapsible sidebar, theme, toasts"`

---

# PHASE 2 — Pipeline data model + Create Tasks landing

### Task 2.1: Migration — pipeline state on tasks

**Files:**
- Create: `db/migrate/XXXX_add_workshop_pipeline_to_tasks.rb`
- Modify: `app/models/task.rb` (additive)
- Test: `test/models/task_pipeline_test.rb`

**Interfaces:**
- Produces: `Task#workshop_stage` enum-like string (`new`/`briefing`/`details`/`ready`), `Task#in_pipeline` boolean, `Task#pipeline_author` (User, optional), scopes `Task.pipeline`, `Task.pipeline_active`; `Task#local_only?` already exists via `external_type.nil?`.

- [ ] **Step 1: Failing test** `test/models/task_pipeline_test.rb`:

```ruby
require "test_helper"

class TaskPipelineTest < ActiveSupport::TestCase
  test "pipeline scope returns only in_pipeline tasks ordered by newest activity" do
    t = tasks(:jira_task) # fixtures are :jira_task, :local_task, :secret_task — there is no tasks(:one)
    t.update!(in_pipeline: true, workshop_stage: "briefing")
    assert_includes Task.pipeline, t
    refute_includes Task.pipeline, tasks(:local_task)
  end

  test "workshop_stage only accepts pipeline stages" do
    t = tasks(:jira_task)
    assert_raises(ArgumentError) { t.workshop_stage = "bogus" }
  end

  test "stage_rank orders new < briefing < details < ready" do
    assert Task::WORKSHOP_STAGES.index("new") < Task::WORKSHOP_STAGES.index("ready")
  end
end
```

- [ ] **Step 2: Run** — `bin/rails test test/models/task_pipeline_test.rb` → FAIL (unknown attribute).
- [ ] **Step 3: Migration**:

```ruby
class AddWorkshopPipelineToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :in_pipeline, :boolean, default: false, null: false
    add_column :tasks, :workshop_stage, :string, default: "new", null: false
    add_column :tasks, :pipeline_entered_at, :datetime
    add_reference :tasks, :pipeline_author, foreign_key: { to_table: :users }, null: true
    add_index :tasks, [:project_id, :in_pipeline, :workshop_stage]
  end
end
```

- [ ] **Step 4: Model additions** in `app/models/task.rb` (append; don't reorder existing code):

```ruby
WORKSHOP_STAGES = %w[new briefing details ready].freeze
enum :workshop_stage, WORKSHOP_STAGES.index_with(&:itself), prefix: :stage
belongs_to :pipeline_author, class_name: "User", optional: true
scope :pipeline, -> { where(in_pipeline: true).order(pipeline_entered_at: :desc) }
scope :pipeline_active, -> { pipeline.where.not(workshop_stage: "ready") }

def enter_pipeline!(author:, stage: "new")
  update!(in_pipeline: true, workshop_stage: stage,
          pipeline_entered_at: pipeline_entered_at || Time.current,
          pipeline_author: pipeline_author || author)
end
```
(No `validate:` on the enum — plain string-backed enum assignment of an unknown value raises `ArgumentError`, which the test asserts. `prefix: :stage` yields the `stage_new?` predicate used in Task 4.1.)

- [ ] **Step 5: Data backfill** (separate `db/migrate/XXXX_backfill_workshop_pipeline.rb`): mark existing brief-flow tasks as pipeline members so in-progress work survives the redesign. Portable Ruby (runs on PG and MySQL), decoupled from app models via AR stubs:

```ruby
class BackfillWorkshopPipeline < ActiveRecord::Migration[8.1]
  class MTask < ActiveRecord::Base; self.table_name = "tasks"; end
  class MBrief < ActiveRecord::Base; self.table_name = "briefs"; end
  class MChatSession < ActiveRecord::Base; self.table_name = "chat_sessions"; end

  def up
    ids = MBrief.distinct.pluck(:task_id) |
          MChatSession.where(purpose: "brief").distinct.pluck(:task_id)
    MTask.where(id: ids).find_each do |t|
      briefed = MBrief.where(task_id: t.id, status: "briefed").exists?
      t.update_columns(in_pipeline: true,
                       workshop_stage: briefed ? "details" : "briefing",
                       pipeline_entered_at: t.pipeline_entered_at || t.created_at)
    end
  end

  def down; end
end
```

- [ ] **Step 6: Migrate + run tests** — `bin/rails db:migrate && bin/rails test test/models/task_pipeline_test.rb` → PASS. Then `bin/rails test` (full suite) → no regressions.
- [ ] **Step 7: Commit** — `git commit -m "feat: workshop pipeline state on tasks (stage, in_pipeline, author)"`

### Task 2.2: Document versions model — unify brief/details versioning

**Files:**
- Create: `db/migrate/XXXX_add_versioning_metadata.rb`
- Modify: `app/models/brief.rb`, `app/models/task_draft.rb`, `app/models/task.rb` (additive)
- Modify: `app/controllers/brief_chat_sessions_controller.rb`, `app/controllers/chat_sessions_controller.rb` (extraction sets source metadata)
- Test: `test/models/document_versioning_test.rb`

**Interfaces:**
- Produces (used by Phases 4–5): on **both** `Brief` and `TaskDraft`: `origin` string ∈ `%w[user ai manual]` (default `ai`), `current` boolean, `label` method → "User description" / "AI drafted" / "Manual edit" / "User description (edited)" (origin `user` + `edited_at` present); `TaskDraft#version` int (backfilled per task by `created_at` order, only `source: "ai"` rows participate); `Task#current_brief`, `Task#current_detail_draft`; `make_current!` (clears siblings' flag in a transaction and, for Jira-linked tasks, does NOT push — push is explicit).
- `Brief` keeps `status` draft/briefed unchanged (briefed == pushed).
- New: `TaskDraft` gains `pushed_at` datetime (details-stage "IN JIRA" badge); `Brief` uses `briefed_at`.

- [ ] **Step 1: Failing test**:

```ruby
require "test_helper"

class DocumentVersioningTest < ActiveSupport::TestCase
  test "make_current! is exclusive per task" do
    task = tasks(:jira_task)
    a = task.briefs.create!(workspace: task.project.workspace, content: "A", version: 1)
    b = task.briefs.create!(workspace: task.project.workspace, content: "B", version: 2)
    b.make_current!
    a.make_current!
    assert a.reload.current?
    refute b.reload.current?
  end

  test "labels derive from origin" do
    task = tasks(:jira_task)
    v = task.briefs.create!(workspace: task.project.workspace, content: "X", version: 1, origin: "user")
    assert_equal "User description", v.label
    v.update!(edited_at: Time.current)
    assert_equal "User description (edited)", v.label
  end

  test "ai drafts get sequential versions per task" do
    task = tasks(:jira_task)
    d1 = task.task_drafts.create!(source: "ai", content: "one")
    d2 = task.task_drafts.create!(source: "ai", content: "two")
    assert_equal d1.version + 1, d2.version
  end
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Migration**:

```ruby
class AddVersioningMetadata < ActiveRecord::Migration[8.1]
  class MBrief < ActiveRecord::Base; self.table_name = "briefs"; end
  class MDraft < ActiveRecord::Base; self.table_name = "task_drafts"; end

  def change
    add_column :briefs, :origin, :string, default: "ai", null: false
    add_column :briefs, :current, :boolean, default: false, null: false
    add_column :briefs, :edited_at, :datetime
    add_column :task_drafts, :origin, :string, default: "ai", null: false
    add_column :task_drafts, :current, :boolean, default: false, null: false
    add_column :task_drafts, :edited_at, :datetime
    add_column :task_drafts, :version, :integer
    add_column :task_drafts, :pushed_at, :datetime
    # "Save locally" flags read by the SAVED LOCALLY badge (Task 4.3)
    add_column :tasks, :brief_saved_locally_at, :datetime
    add_column :tasks, :detail_saved_locally_at, :datetime
    # Plain (non-partial) indexes — MySQL has no partial indexes; exclusivity of
    # `current` is enforced by make_current!'s transaction, not the DB.
    add_index :briefs, [:task_id, :current]
    add_index :task_drafts, [:task_id, :source, :current]
    reversible do |dir|
      dir.up do
        # Portable Ruby backfill (must run on PG dev/test AND MySQL prod)
        MDraft.distinct.pluck(:task_id, :source).each do |task_id, source|
          MDraft.where(task_id: task_id, source: source).order(:created_at)
                .each_with_index { |d, i| d.update_columns(version: i + 1) }
        end
        MBrief.group(:task_id).maximum(:version).each do |task_id, max_v|
          MBrief.where(task_id: task_id, version: max_v).update_all(current: true)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Shared concern** `app/models/concerns/versionable_document.rb`:

```ruby
module VersionableDocument
  extend ActiveSupport::Concern

  included do
    scope :current, -> { where(current: true) }
    validates :origin, inclusion: { in: %w[user ai manual] }
  end

  def label
    case origin
    when "user"   then edited_at? ? "User description (edited)" : "User description"
    when "manual" then "Manual edit"
    else "AI drafted"
    end
  end

  def make_current!
    transaction do
      siblings_scope.update_all(current: false)
      update!(current: true)
    end
  end
end
```
`Brief` includes it with `def siblings_scope = task.briefs`; `TaskDraft` with `def siblings_scope = task.task_drafts.by_source(source)`. `TaskDraft` gains `before_create { self.version ||= (task.task_drafts.by_source(source).maximum(:version) || 0) + 1 }`.
`Task` gains `def current_brief = briefs.current.first || briefs.newest_first.first` and `def current_detail_draft = task_drafts.by_source("ai").current.first || latest_draft`.
- [ ] **Step 5: Extraction updates**: in `brief_chat_sessions_controller.rb#extract_and_save_results`, after creating each Brief add `.make_current!`; same for `chat_sessions_controller.rb` AI drafts. New Brief/TaskDraft rows from AI keep `origin: "ai"` (default).
- [ ] **Step 6: Run tests** (`bin/rails test`) → PASS, no regressions (breakdown drafts unaffected: version auto-assign is harmless).
- [ ] **Step 7: Commit** — `git commit -m "feat: version metadata (origin/current/labels) for briefs and drafts"`

### Task 2.3: Workshop namespace + Create Tasks landing page

**Files:**
- Create: `app/controllers/workshop/base_controller.rb`, `app/controllers/workshop/pipeline_controller.rb`, `app/controllers/workshop/ideas_controller.rb` (create/update/rename in Phase 3–4)
- Create: `app/views/workshop/pipeline/index.html.erb`, `app/views/workshop/pipeline/_idea_row.html.erb`
- Create: `app/javascript/controllers/clar_pipeline_filter_controller.js`
- Modify: `config/routes.rb` (additive block), `app/views/layouts/_clar_sidebar.html.erb` (flip Create Tasks route + badge)
- Modify: `app/controllers/workshop_controller.rb` — `index` becomes `redirect_to workshop_pipeline_path`
- Test: `test/controllers/workshop/pipeline_controller_test.rb`

**Interfaces:**
- Produces routes:

```ruby
# config/routes.rb — insert after the existing workshop block
namespace :workshop do
  get  "pipeline", to: "pipeline#index", as: :pipeline
  resources :ideas, only: [:create, :show, :update] do
    member do
      post :advance          # stage transitions (Phase 4)
      post :save_locally
      post :push_jira
    end
    resources :versions, only: [:create, :update] do  # Phase 5 (manual edits)
      member { post :make_current }
    end
    resource :design_request, only: [:create, :update, :destroy]  # Phase 5
  end
  get "process",       to: "process#show",       as: :process        # Phase 6
  get "reporting",     to: "reports#show",       as: :reporting      # Phase 7
  get "bugs",          to: "bugs#show",          as: :bugs           # Phase 8
  get "configuration", to: "configuration#show", as: :configuration  # Phase 9
end
```
(Add only the routes for the current phase; the block above is the target end-state — keep this exact naming.)
- Produces: `Workshop::BaseController < ApplicationController` with `layout "workshop"`, `include WorkspaceScoped`, `before_action :require_product!(:workshop)` equivalents copied from `WorkshopController`'s current guards **minus** `require_admin!` (D1: employees with `workshop_access` allowed; keep `require_workshop!`), `before_action :set_pipeline_badge` (`@pipeline_badge_count = current_workshop_project ? current_workshop_project.tasks.pipeline_active.count : 0`), helper `current_workshop_project` already available.

- [ ] **Step 1: Failing controller test** — pipeline index renders rows, filters by stage/source/search, sorts:

```ruby
require "test_helper"

class Workshop::PipelineControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    @task = tasks(:jira_task) # Jira-synced fixture (project projects(:jira_project), key ELV-1)
    @task.update!(in_pipeline: true, workshop_stage: "briefing", pipeline_entered_at: 1.hour.ago)
  end

  test "lists pipeline ideas with stage badge" do
    get workshop_pipeline_path
    assert_response :success
    assert_select "h1", "Create Tasks"
    assert_select ".clar-row", minimum: 1
    assert_select ".clar-badge", /Briefing/
  end

  test "stage filter narrows the list" do
    get workshop_pipeline_path(stage: "ready")
    assert_select ".clar-row", count: 0
    assert_select "[data-empty]", /No tickets match/
  end

  test "search matches key and title" do
    get workshop_pipeline_path(q: @task.external_reference.to_s)
    assert_select ".clar-row", minimum: 1
  end
end
```

- [ ] **Step 2: Run** → FAIL (no route).
- [ ] **Step 3: Controller** `Workshop::PipelineController#index`:

```ruby
class Workshop::PipelineController < Workshop::BaseController
  STAGE_ORDER_SQL = "CASE workshop_stage WHEN 'new' THEN 0 WHEN 'briefing' THEN 1 " \
                    "WHEN 'details' THEN 2 ELSE 3 END".freeze

  def index
    # NEVER redirect to workshop_path here — WorkshopController#index redirects
    # back to the pipeline (Step 5), which would loop. Render an empty state.
    return render :no_project unless current_workshop_project

    scope = current_workshop_project.tasks.pipeline
    scope = scope.where(workshop_stage: params[:stage]) if Task::WORKSHOP_STAGES.include?(params[:stage])
    scope = case params[:source]
            when "jira"  then scope.jira_synced
            when "local" then scope.local_only
            else scope
            end
    if params[:q].present?
      # LOWER(...) LIKE, not ILIKE — must run on MySQL in production
      q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].downcase)}%"
      scope = scope.left_joins(:pipeline_author).where(
        "LOWER(tasks.name) LIKE :q OR LOWER(tasks.external_reference) LIKE :q OR LOWER(users.name) LIKE :q", q: q
      )
    end
    @ideas = case params[:sort]
             when "oldest" then scope.reorder(pipeline_entered_at: :asc)
             when "stage"  then scope.reorder(Arel.sql(STAGE_ORDER_SQL))
             when "title"  then scope.reorder(:name)
             else scope
             end
    @counts = current_workshop_project.tasks.pipeline.group(:workshop_stage).count
    @source_counts = { all: current_workshop_project.tasks.pipeline.count,
                       jira: current_workshop_project.tasks.pipeline.jira_synced.count,
                       local: current_workshop_project.tasks.pipeline.local_only.count }
  end
end
```
`no_project.html.erb`: centered `clar-card` — "No Jira project connected. Connect a project in Projects (Time & HR) to use the Workshop." with a link for admins. (Search matches title/key/author; the mockup also matched its synthetic `IDEA-…` ids, which don't exist here — numeric task ids are not user-visible, deliberately skipped.)

- [ ] **Step 4: View** `index.html.erb` — mockup copy verbatim:
  - `<h1 class="clar-h1">Create Tasks</h1>` + `<p class="clar-sub">Turn rough ideas and unclear tickets into implementation-ready Jira tasks. The AI reads the repo first, then helps you shape them.</p>`
  - Two `clar-card clar-card-hover` entry cards (grid-cols-2): **New idea** ("Name it first so it's saved — then talk it through anytime. Stays local until you push it to Jira.") opens the new-idea modal (Phase 3, `data-action="clar-modal#open"`); **Existing Jira task** ("Browse your Jira boards — design, development, backlog — and pull a ticket in to refine.") opens the Jira browser modal (Phase 3).
  - "IN THE PIPELINE" `clar-section-label` row + right controls: search input (`name=q`, placeholder "Search tickets…") and sort `clar-select` (Newest first/Oldest first/Pipeline stage/Title A–Z) inside a GET form (`data-controller="clar-pipeline-filter"` auto-submits on change / debounced input 300 ms — full-page GET keeps state in URL, matching existing app patterns).
  - Stage chips (All/New/Briefing/Details/Ready with counts) + divider + source chips (All sources/In Jira/Local ideas — dark active style) — plain `<a>` links preserving other params.
  - Rows via `_idea_row.html.erb`: LOCAL badge or `clar-key` chip; title; "{author} · Created {clar_time_ago}"; design badges ("Designs requested" warn / "Designs ready" success — from Phase 5 association, guard with `if idea.design_request&.requested?` etc.); stage badge map — `new→clar-badge-muted "New idea"`, `briefing→clar-badge-primary "Briefing"`, `details→clar-badge-ai "Details Gathering"`, `ready→clar-badge-success "Ready · in Jira"` (LOCAL ready shows "Ready · local"); chevron. Row links to `workshop_idea_path(idea)`.
  - Empty state `<div data-empty class="…">No tickets match your search or filter.</div>` (dashed border, centered).
- [ ] **Step 5: Redirect old landing** — `WorkshopController#index` → `redirect_to workshop_pipeline_path` (keep `require_*` guards so redirects still enforce access; leave `new_idea`/`start`/`brief` untouched until Phases 3–4 replace them).
- [ ] **Step 6: Sidebar flip** — Create Tasks nav item now uses `workshop_pipeline_path` + `@pipeline_badge_count` badge.
- [ ] **Step 7: Run tests** → PASS. Full suite → green.
- [ ] **Step 8: Commit** — `git commit -m "feat: Create Tasks pipeline landing (filters, search, stage badges)"`

---

# PHASE 3 — Idea intake: New-idea modal + Jira board browser

### Task 3.1: New idea modal

**Files:**
- Create: `app/views/workshop/pipeline/_new_idea_modal.html.erb`
- Modify: `app/controllers/workshop/ideas_controller.rb` (`create`)
- Test: extend `test/controllers/workshop/ideas_controller_test.rb`

**Interfaces:**
- Consumes: `Task.enter_pipeline!`, `clar_toast`.
- Produces: `POST /workshop/ideas` params `{ idea: { title:, description: } }` → builds local task with `task = current_workshop_project.tasks.new(name: title, description: desc)`; on `task.save` → `enter_pipeline!(author: current_user, stage: "briefing")`, seed v0 Brief when description present — the **full** call (Brief requires workspace; explicit version 0 avoids colliding with `Brief.next_version_for`, which starts AI drafts at 1):

```ruby
task.briefs.create!(workspace: task.project.workspace, version: 0,
                    origin: "user", status: "draft", content: desc).make_current!
```
  then redirect to `workshop_idea_path(task)` with `clar_toast(%(Idea saved · "#{title}"))`. On save failure (blank title OR duplicate — `Task` validates name uniqueness per project, `task.rb:39`) → re-render with `status: :unprocessable_entity` surfacing `task.errors`.

- [ ] **Step 1: Failing test** — posting title creates pipeline task at briefing and redirects to workspace; blank title → 422; **duplicate title → 422 with error message** (not a 500); description seeds a v0 user brief (version 0, current, origin "user").
- [ ] **Step 2–3: Implement controller + modal.** Modal per mockup: title "New idea", copy "Give it a title so it's saved to the pipeline — you can come back to the conversation anytime.", TITLE\* input (placeholder "e.g. Aggregated CSV export for analysts", Enter submits), DESCRIPTION optional textarea ("A sentence or two on what you're thinking…"), Cancel / "Save & start briefing" (disabled until title — small inline Stimulus `clar_required_controller.js` or reuse `disabled` toggling inside `clar_modal_controller.js` via `input` action).
- [ ] **Step 4: Tests pass; commit** — `git commit -m "feat: new-idea modal creates pipeline idea and seeds v0 description"`

### Task 3.2: Browse Jira boards modal (kanban + backlog table)

**Files:**
- Create: `app/controllers/workshop/jira_browser_controller.rb` + route **inside the `namespace :workshop` block**: `get "jira_browser", to: "jira_browser#show", as: :jira_browser` (→ `/workshop/jira_browser`, helper `workshop_jira_browser_path`; the turbo-frame `src` uses the helper, never a hardcoded path)
- Create: `db/migrate/XXXX_add_jira_reporting_columns_to_tasks.rb` — `add_column :tasks, :story_points, :decimal, precision: 5, scale: 1` + `add_column :tasks, :jira_created_at, :datetime` (needed by the PTS pill and Newest/Oldest sorts NOW; they stay empty — PTS renders "—", date sorts use `COALESCE(jira_created_at, created_at)` — until Task 6.2's sync fills them)
- Create: `app/views/workshop/jira_browser/show.html.erb` (turbo-frame content), partials `_board_kanban.html.erb`, `_backlog_table.html.erb`
- Create: `app/javascript/controllers/clar_board_filter_controller.js` (client-side text filter of rendered cards)
- Modify: `app/controllers/workshop/ideas_controller.rb` (`create` accepts `task_id` import mode)
- Test: `test/controllers/workshop/jira_browser_controller_test.rb`

**Interfaces:**
- Consumes: `JiraBoard` → `jira_board_columns` → `jira_board_column_statuses`, `JiraSprint.active_or_future`, `current_workshop_project.tasks.jira_synced`, board-grouping pattern from `JiraTasksController#board_data`.
- Produces: modal shell on the pipeline page lazy-loads `<turbo-frame id="clar-jira-browser" src="/workshop/jira_browser">`; frame shows board tabs (each synced `JiraBoard` + a synthetic **Backlog** tab), sprint label (board's active sprint name or "Filtered: no sprint"), search box (client-side filter, hidden on Backlog), kanban columns (statuses → tasks not in pipeline yet) or backlog table (tasks with `sprint_id: nil`), with the mockup's TYPE chips (All/Story/Task/Bug on `issue_type`), SORT select (Priority order High>Medium>Low via `CASE priority WHEN 'High'…`, points N/A → last, newest/oldest by `jira_created_at` fallback `created_at`, title), priority dot colors, PTS column (`story_points` — shows `—` until Phase 7 sync lands; acceptable), REPORTER (`reporter_name`).
- Import: each card/row is a `button_to workshop_ideas_path, params: { task_id: t.id }` → `task.enter_pipeline!(author: current_user, stage: "briefing")` (`author:` is a required keyword) on the existing task; **seed v0 from the imported description** exactly like Task 3.1 (mockup seeds v0 on import too): if `task.description.present?` create the version-0 user Brief and `make_current!`; redirect to workspace, toast `Imported {KEY} from Jira`. Already-pipelined tasks are excluded from the browser.

- [ ] **Step 1: Failing test** — frame renders board tabs from fixtures; backlog tab renders table; POST import puts task in pipeline + redirects.
- [ ] **Step 2–4: Implement.** Copy from mockup: modal title "Browse Jira boards", copy "Pick a ticket from any board to refine — it opens in Briefing. Click a card to pull it in."; kanban card = title (2-line clamp), type dot (Story `--success` / Task `--primary` / Bug `--danger`), `clar-key`-style mono key (faint variant), pts pill when present, assignee initials avatar ("·" when unassigned); empty column dashed "—"; backlog empty "No tickets match."
- [ ] **Step 5: Tests pass; full suite; commit** — `git commit -m "feat: Jira board browser modal — kanban + backlog grooming import"`

---

# PHASE 4 — Idea workspace: stepper shell + Briefing stage

### Task 4.1: Workspace page shell (stepper, rename, stage routing)

**Files:**
- Create: `app/views/workshop/ideas/show.html.erb`, partials `_workspace_header.html.erb`, `_stepper.html.erb`
- Modify: `app/controllers/workshop/ideas_controller.rb` (`show`, `update` for rename, `advance`)
- Create: `app/javascript/controllers/clar_rename_controller.js`
- Test: `test/controllers/workshop/ideas_controller_test.rb` additions

**Interfaces:**
- `GET /workshop/ideas/:id` → `@idea` (task, scoped `current_workshop_project.tasks.pipeline`), `@stage = params[:stage].presence_in(%w[briefing details ready]) || (@idea.stage_new? ? "briefing" : @idea.workshop_stage)`; navigating to a done/current step is a plain link `workshop_idea_path(@idea, stage: "briefing")`.
- `PATCH /workshop/ideas/:id` `{ idea: { name: } }` → rename (local tasks rename freely; Jira tasks rename local mirror only — show hint), toast `Renamed`.
- `POST advance` `{ to: }` — server-side guard of legal transitions (`new→briefing`, `briefing→details` (push or explicit), `details→ready`); sets `workshop_stage`.
- Header per mockup: "← All tasks" → pipeline; key chip when Jira-linked; H1 + pencil (Stimulus swaps to input; Enter/blur PATCH via fetch, Escape cancels); stepper with ✓/number circles and connector lines; uses `content_for :clar_full_bleed`.

- [ ] Steps: failing test (show renders stepper at right stage; rename updates name; illegal advance → 422) → implement → PASS → commit `feat: idea workspace shell — stepper, rename, stage routing`.

### Task 4.2: Port the brief chat to the Briefing stage (left panel)

**Files:**
- Create: `app/views/workshop/ideas/_chat_panel.html.erb`, `app/javascript/controllers/clar_chat_controller.js`
- Modify: `app/controllers/brief_chat_sessions_controller.rb` — replace `require_admin!` with `require_workshop_member!` (D1); keep routes as-is (`/jira_tasks/:id/brief_chat_session…`) — they work for any task id. **The guard must be explicit** — `/jira_tasks/*` is client-allowed by `redirect_clients_to_jira` and `User#can_access_workshop?` returns true for clients, so reusing `require_product!`/`can_access_workshop?` would silently let clients spawn AI sessions. New helper in `app/controllers/concerns/authorization.rb`:

```ruby
def require_workshop_member!
  membership = current_user.workspace_memberships.find_by(workspace: Current.workspace)
  return if membership && !membership.client? && membership.workshop_access

  redirect_to root_path, alert: "Not authorized"
end
```
  `Workshop::BaseController` uses the same guard (its "minus require_admin!" note in Task 2.3 means exactly this helper). Add a test: `users(:client_user)` gets redirected from brief-chat create/message.
- Test: JS-free controller test that SSE endpoints still authorize; view test that panel targets exist

**Interfaces:**
- `clar_chat_controller.js` = port of `task_chat_controller.js`'s SSE core (create/resume/message/reset/render-markdown), re-skinned to Clar bubbles, minus the panel-state machine (workspace grid handles layout), plus: values `createUrl`, `showUrl`, `messageUrl`, `resetUrl`, `persona` ("briefing"/"details"); strips `<brief>`/`<draft>` blocks from bubbles and dispatches `clar:document-updated` event so the right panel refreshes (Turbo frame reload); typing dots (three `clar-blink` dots); Enter-to-send.
- Persona banner row: star badge "Briefing · acts like a Product Owner" + "Reads project & task description first" + **Reset session** button → confirmation modal (Task 4.4).
- Empty-chat seeding: initial AI message comes from the SSE create call exactly as today.

- [ ] Steps: extract-and-port JS (keep `task_chat_controller.js` untouched — Jira Tasks page still uses it) → wire panel → verify manually with a live CLI chat → commit `feat: Clar chat panel for briefing stage`.

### Task 4.3: Document panel — versions, view mode, actions (briefing flavor)

**Files:**
- Create: `app/views/workshop/ideas/_document_panel.html.erb` (turbo-frame `clar-document`), `app/controllers/workshop/versions_controller.rb`
- Modify: `app/controllers/workshop/ideas_controller.rb` (`save_locally`, `push_jira`)
- Test: `test/controllers/workshop/versions_controller_test.rb`

**Interfaces:**
- Frame renders: header "Brief" + version chips (v0…vn from `task.briefs` ordered by version; selected via `?v=` param; green-dot on `current`), Edit button, panel-size (focus) toggle; body: meta row (v{n} · time-ago, source badge from `label`; **CURRENT** badge when selected==current; **IN JIRA** badge only when selected==current AND the stage's push flag is set (`brief.briefed?` here, `draft.pushed_at?` in details); **SAVED LOCALLY** only when selected==current AND not pushed AND `tasks.brief_saved_locally_at` (briefing) / `detail_saved_locally_at` (details) is set — the flag is stamped by `POST save_locally` and cleared on a successful push), content rendered as markdown → HTML through a **server-side renderer**: add `app/helpers/clar_markdown_helper.rb` using `Commonmarker`? — **No new gems**: reuse the same conservative regex renderer the JS uses by rendering client-side: content div `data-clar-markdown` + tiny `clar_markdown_controller.js` that ports `task_chat_controller.js`'s `renderMarkdown` (single shared module `app/javascript/lib/clar_markdown.js`, imported by chat + document + history controllers; add to importmap).
- Footer (view mode): if selected ≠ current → `clar-btn-ai clar-btn-block` **"Set v{n} as current · update Jira description"** (Jira-linked) / **"Set v{n} as current · update local description"** (local) → `POST versions/:id/make_current`: `make_current!` + write plain text back to `tasks.description`, and for **any Jira-linked task** (briefed or not — mockup semantics, lines 515–520) also push via `JiraWriter` (`update_issue_description`); toast `v{n} set as current · Jira description updated` / `· local description updated`.
  Row: **Reset chat** (Task 4.4 light reset) + **Save locally** → `POST save_locally` (briefing: stamps `brief_saved_locally_at`, toast `Brief saved to the task locally · not pushed`; keeps stage).
  Primary: **Brief & mark Briefed** → `POST push_jira` (stage=briefing) → `JiraWriter#commit_brief(current_brief)` — existing behavior (creates issue for local ideas, sets AI actions=Briefed); on success clear `brief_saved_locally_at`, `advance` to `details`, toast `Pushed to Jira · AI actions = Briefed`; on failure re-render with `clar_toast(error)` styled as alert.
- Empty state (no versions) — four description-block variants, copy verbatim: label "CURRENT JIRA DESCRIPTION" (Jira-linked) / "TASK DESCRIPTION" + key chip or `LOCAL · NOT IN JIRA` badge; Jira-linked with description → plain text block; Jira-linked without → italic *"This Jira task has no description yet."*; local with description → text in an **amber box** (`--warn-soft` background, dashed `--warn` border); local without → italic *"No description yet — talk it through below."* Always followed by the AI explainer box (copy verbatim from mockup lines 909–912); footer hint "The AI drafts the brief as you talk".

- [ ] Steps: failing tests (make_current exclusivity via HTTP; push_jira advances stage on writer `{ok: true}` — stub `JiraWriter` with a Minitest mock; save_locally toast) → implement → PASS → commit `feat: briefing document panel — versions, set-current, push to Jira`.

### Task 4.4: Reset session modal + Reset chat

**Files:**
- Create: `app/views/workshop/ideas/_reset_modal.html.erb`
- Modify: `clar_chat_controller.js` (two reset actions), `app/controllers/concerns/chat_streaming.rb` — **no change needed** (destroy already soft-closes and keeps documents; verify only)
- Test: request test — DELETE brief_chat_session keeps briefs

**Behavior contract (from mockup):**
- **Reset session** (header): modal "Reset AI session" — copy "Restarts this briefing/details conversation from scratch — the AI re-reads the code. **All saved versions and the description are kept**." + KEPT box showing current description; confirm → `DELETE` session endpoint, then `create` a fresh one (opener seeds itself), toast `Chat reset · all versions kept`.
- **Reset chat** (document footer): no modal; `DELETE` then `create` with extra param `mode=refine_current` — `build_initial_prompt` for brief gains an optional paragraph when `params[:mode] == "refine_current"`: "The team already has a current version of the brief (included below). Ask what should change instead of starting from zero." + current content. Toast `Conversation reset — current version kept`.

- [ ] Steps: failing test (reset preserves Brief rows; `mode` param alters prompt — assert via a captured-prompt seam: extract `build_initial_prompt` output in a unit test of the controller class) → implement → commit `feat: two-tier chat reset (session vs conversation) with versions kept`.

---

# PHASE 5 — Details stage, rich-text editing, designs flow, Ready screen

### Task 5.1: Details Gathering stage (reuse "refine" purpose) + push

**Files:**
- Modify: `app/views/workshop/ideas/show.html.erb` (+ document panel details flavor), `app/controllers/workshop/ideas_controller.rb#push_jira`
- Modify: `app/services/jira_writer.rb` — add `commit_detail(task_draft)`. Real APIs: `update_issue_description` is **keyword-only** (`issue_key:`, `description_text:` — `jira_client.rb:212`), the writer uses `@client` (no reader), and `JiraClient#add_ai_action` already accepts arbitrary `value:` — so first **extract** a private `set_ai_action(issue_key, value)` from `commit_brief`'s inline block (including its field-id-blank error branch via `ai_actions_field_id`), then:

```ruby
DETAILED_VALUE = "Detailed"

def commit_detail(draft)
  task = draft.task
  return { ok: false, error: "Task is not linked to Jira" } if task.external_reference.blank?

  res = @client.update_issue_description(issue_key: task.external_reference,
                                         description_text: draft.content)
  return res unless res[:ok]

  action = set_ai_action(task.external_reference, DETAILED_VALUE)
  return action unless action[:ok]

  draft.update!(pushed_at: Time.current)
  { ok: true }
end
```
  `commit_brief` is refactored to call the same `set_ai_action(…, BRIEFED_VALUE)` — behavior unchanged (existing writer tests must stay green).
- Modify: `app/controllers/chat_sessions_controller.rb` — the details chat IS the refine purpose; its prompt already matches the "senior partner" persona. Add the same `mode=refine_current` hook and inject `current brief` content into the initial prompt when the task has one (mockup: "Briefed version is in. I've re-read …").
- Test: writer unit test with stubbed `JiraClient`; controller test for details push advancing to ready.

**Behavior:** Details stage chat = purpose "refine" (existing SSE endpoints under `/jira_tasks/:id/chat_session`); document panel binds to `task_drafts` (source "ai"): chips, set-current, edit, **Brief history** button (modal listing `task.briefs` versions read-only + "Back to briefing to improve" → link to `?stage=briefing`); **v0 seeding**: on first entering the details stage, if the task has no `source: "ai"` drafts and `task.description.present?`, seed `task.task_drafts.create!(source: "ai", origin: "user", version: 0, content: task.description).make_current!` so the panel shows a v0 USER DESCRIPTION chip (mockup seeds both stages' version lists; `TaskDraft`'s `before_create` uses `||=` so the explicit 0 survives); primary button "Update Jira description" (Jira-linked) / "Push to Jira" (local, disabled with tooltip "Push the brief first to create the Jira issue" — local ideas without a key cannot receive a details push; mockup allows it by assigning a key, but our real flow creates issues only via `commit_brief`; Open Decision D3); **Save locally** → stamps `detail_saved_locally_at`, advances to `ready` (LOCAL badge), toast `Saved to the task locally · finished without Jira`. Successful push → clear `detail_saved_locally_at`, stage `ready`, toast `Description sent to Jira · marked Detailed`.

- [ ] Steps: failing tests → implement → PASS → commit `feat: details-gathering stage with push-to-Jira (AI actions = Detailed)`.

### Task 5.2: Rich-text version editing

**Files:**
- Create: `app/javascript/controllers/clar_editor_controller.js`
- Modify: `app/controllers/workshop/versions_controller.rb` (`create` = save-as-new, `update` = save-in-place), `_document_panel.html.erb`
- Test: versions controller tests

**Interfaces:**
- Edit mode swaps the body for: hint "Editing v{n} — save in place, or save as a new version.", toolbar (Bold/Italic/bullet/numbered/H/¶/code/link via `document.execCommand` exactly like the mockup) + `contenteditable` `clar-editor clar-prose` div seeded with the rendered HTML.
- Save-in-place: `PATCH /workshop/ideas/:idea_id/versions/:id` `{ kind: "brief"|"detail", content_html: }` → server converts HTML→markdown-ish plain text? **No.** Store HTML as-is in `content` and mark the row `origin` unchanged + `edited_at = now` (label becomes "(edited)" for user rows). Rendering side detects HTML (`content.lstrip.start_with?("<")`) and skips the markdown pass. Jira pushes already flatten to plain text via `JiraClient#adf` wrapper — add an HTML→text strip (`ActionText::Fragment`? No — use `Rails::Html::FullSanitizer.new.sanitize(content)` then squeeze blank lines) inside `JiraWriter` when content is HTML. Toast `Saved v{n}`.
- Save-as-new: `POST …/versions` `{ kind:, content_html: }` → new row `origin: "manual"`, next version, `make_current!`, toast `Saved as new version · now current`.
- Sanitize on render: pass stored HTML through `sanitize(content, tags: %w[h4 p b strong i em ul ol li pre code a br], attributes: %w[href])` in the view.

- [ ] Steps: failing tests (create manual version becomes current; update stamps edited_at; sanitizer strips scripts) → implement → PASS → commit `feat: rich-text editing of brief/description versions`.

### Task 5.3: Designs flow (request → delivered, Figma links)

**Files:**
- Create: `db/migrate/XXXX_create_design_requests.rb`, `app/models/design_request.rb`
- Create: `app/controllers/workshop/design_requests_controller.rb`, views `_designs_strip.html.erb`, `_request_designs_modal.html.erb`
- Modify: `app/models/task.rb` (`has_one :design_request` — exactly one row per task, enforced by the unique index; "Request changes" transitions the SAME row's status back, preserving links/history), `_idea_row.html.erb` badges
- Test: model + controller tests

```ruby
class CreateDesignRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :design_requests do |t|
      t.references :task, null: false, foreign_key: true, index: { unique: true }
      t.references :requester, null: false, foreign_key: { to_table: :users }
      t.references :designer,  null: false, foreign_key: { to_table: :users }
      t.string  :status, null: false, default: "requested" # requested|delivered|cancelled
      t.text    :note
      t.json    :links   # [{"name":,"url":}] — :json not :jsonb (MySQL prod); default [] set in the model
      t.datetime :delivered_at
      t.timestamps
    end
  end
end
```
Model: `attribute :links, default: []` (MySQL JSON columns cannot carry a DB default).

**Behavior (mockup-faithful):** strip visible in details+ready; states/copy verbatim ("Optional · the designer prepares these — request them before or after details, whenever this task needs them."); Request modal picks designer from `Current.workspace.users` (all members — no designer role exists; D4) + optional note, toast `Design request sent to {name}`; **Mark delivered** opens a small inline form to paste link rows (name auto = "Figma frame {n}" when blank) → save + sync to Jira (below), toast `Designs delivered · {n} links added to Jira description`; **Cancel** → status cancelled, toast `Design request cancelled`; **Request changes** → status back to `requested` on the same row (designer may be swapped; links kept). Pipeline badges from `status`.
**Jira description sync:** the description carries a delimited block (`--- Designs ---` + one `{name}: {url}` line each). New `JiraWriter#sync_design_links(task, links)` **rewrites that block idempotently** — called on delivery, on per-link removal (mockup line 808), and on request-changes — so the IN DESCRIPTION badge is always truthful; removing the last link removes the block.
No Discord notification in this task — `DiscordGroupClient` posts into the HR reminders group DM (an HR-owned channel; posting Workshop noise there would change HR-visible behavior). An optional webhook-based notification lands with Task 6.4's `DiscordWebhook` model instead.

- [ ] Steps: failing tests → implement → PASS → commit `feat: design request flow with Figma links pushed to Jira description`.

### Task 5.4: Ready screen

**Files:**
- Create: `app/views/workshop/ideas/_ready.html.erb`
- Create: `app/javascript/controllers/clar_copy_controller.js` (clipboard + toast)
- Modify: `app/controllers/workshop/ideas_controller.rb#show` (stage ready branch loads summary data)
- Test: view/controller test

**Data mapping:** AI actions → "Detailed" when `current_detail_draft&.pushed_at` else "Briefed" when brief briefed else "—". AI estimation → `task.ai_estimate_points` (Phase 6; until then latest breakdown total via `task.latest_breakdown` JSON `total_points`) + label "· auto". Designs → request state. Versions saved → `task.briefs.count + task.task_drafts.by_source("ai").count`. Branch name:

```ruby
def suggested_branch
  slug = name.parameterize[0, 32].delete_suffix("-")
  key  = external_reference&.downcase
  "feat/#{[key, slug].compact.join("-")}"
end
```
Copy button copies `git checkout {branch}`, toast `Checkout command copied`. Push-to-Jira button shown when not pushed (`detail draft pushed_at nil && brief not briefed` for locals) → same `push_jira` endpoint. "Back to pipeline" → `workshop_pipeline_path`. Copy verbatim from mockup (headline, sub-copies for pushed/local, branch explainer). **No server-side git operations** — the card is informational (honest copy: keep mockup text; the branch is a suggestion).

- [ ] Steps: failing test → implement → PASS → commit `feat: Ready-for-the-team screen with estimate, branch suggestion, push`.

---

# PHASE 6 — Process Optimization (PR Reviews · AI Estimate · AI Alerts)

### Task 6.1: PR review metadata + feed tab

**Files:**
- Create: `db/migrate/XXXX_add_metadata_to_pr_reviews.rb` (`pr_title` string, `pr_author` string, `pr_branch` string, `pr_url` string, `comment_count` integer, `outcome` string default "pending" — pending|looks_good|comments) **plus** `add_column :workspaces, :pr_poll_minutes, :integer, default: 7, null: false` and `add_column :workspaces, :pr_polled_at, :datetime` (needed by this task's chip; Task 9.1 only adds the slider UI). `pr_polled_at` is a NEW dedicated timestamp — do NOT reuse `github_status_checked_at`, which HR's Workspace Settings "Test GitHub" button also writes (reusing it would let an HR click postpone polling and fake the chip).
- Modify: `app/jobs/pr_review_check_job.rb` — stamp `workspace.pr_polled_at` each poll; skip a workspace unless `pr_polled_at.nil? || pr_polled_at <= now - max(7, pr_poll_minutes).minutes`
- Modify: `app/jobs/pr_review_job.rb` — after fetching the PR, persist title/author(login)/branch(head ref)/html_url; after posting, set `outcome` (`comments`/`looks_good`) + `comment_count`
- Create: `app/controllers/workshop/process_controller.rb` (`show`, `?tab=pr|estimate|alerts`), `app/views/workshop/process/show.html.erb`, `_pr_tab.html.erb`
- Modify: routes (add `get "process"`), sidebar flip
- Test: job unit test (stubbed GithubClient + CLI), controller test

**UI (verbatim copy):** header "Three AI automations watching this project. They comment and propose — humans decide."; `clar-tabs` AI PR Reviews / AI Estimate / AI Alerts; stats trio computed from `pr_reviews` where `reviewed_at >= Time.current.beginning_of_day` (reviewed today / outcome counts); polling chip "Polling every {max(7, workspace.pr_poll_minutes)} min · last {clar_time_ago(workspace.pr_polled_at)}"; feed rows (last 20 by reviewed_at desc): `#num`, title, "{author} · {branch mono} · {time-ago}", outcome pill "Looks good!"/"{n} comments", "GitHub ↗" link to `pr_url`; footer disclaimer line. Empty state when `pr_review_enabled` is off: card linking to Configuration.

- [ ] Steps: failing tests → migration → job persistence (existing rows keep outcome pending — feed copes) → UI → PASS → commit `feat: AI PR review feed with outcomes`.

### Task 6.2: Story points & estimation plumbing (sync + settings)

**Files:**
- Create: `db/migrate/XXXX_add_estimation_fields.rb` (`tasks.story_points` + `tasks.jira_created_at` already exist from Task 3.2):

```ruby
add_column :tasks, :ai_estimate_points, :decimal, precision: 5, scale: 1
add_column :tasks, :ai_estimated_at, :datetime
add_column :workspaces, :estimation_trigger, :string, null: false, default: "manual" # sprint|status|briefed|manual
add_column :workspaces, :estimation_field_names, :json  # default ["AI estimation"] set in the MODEL (MySQL: no JSON defaults)
add_column :workspaces, :estimation_status_trigger, :string, default: "Ready for dev"
add_column :workspaces, :jira_story_points_field_id, :string
add_column :workspaces, :jira_ai_estimation_field_id, :string

create_table :delivered_issues do |t|
  t.references :project, null: false, foreign_key: true
  t.string  :jira_key, null: false
  t.string  :title
  t.string  :issue_type
  t.string  :assignee_email
  t.string  :assignee_name
  t.string  :reporter_email
  t.string  :reporter_name
  t.decimal :story_points, precision: 5, scale: 1
  t.datetime :jira_created_at
  t.datetime :resolved_at
  t.timestamps
  t.index [:project_id, :jira_key], unique: true
  t.index [:project_id, :resolved_at]
end
```
Workspace model: `def estimation_field_names = (super.presence || ["AI estimation"])`.
- **Done issues go into the new `delivered_issues` mirror table, NEVER into `tasks`.** HR's Projects index renders `project.tasks.size` (`app/views/projects/index.html.erb:33`); upserting ~400 days of done issues into `tasks` would visibly change that HR screen. `DeliveredIssue` is a Workshop-only reporting mirror holding everything Phases 7–8 need (key, points, assignee, reporter, type, created, resolved).
- Modify: `app/services/jira_client.rb` — extend `fetch_issues` field list with the resolved story-points custom field (new `resolve_story_points_field`: find "Story point estimate" or "Story Points" via existing `fetch_field_id`, cache on `workspaces.jira_story_points_field_id`) + `created`; add **second pass** `fetch_recent_done_issues(project_key, since:)` (JQL `project = X AND statusCategory = Done AND updated >= -400d`, fields: summary/issuetype/assignee/reporter/points/created/resolutiondate — no comments/attachments); add `set_number_field(issue_key:, field_id:, value:)` write (keyword args, same `{ok:, error:}` contract).
- Modify: `app/services/jira_sync_service.rb` — open-issue pass now also fills `tasks.story_points` + `tasks.jira_created_at`; new `sync_delivered_issues` upserts `DeliveredIssue` by `[project_id, jira_key]`.
- Test: sync service test with a stubbed client fixture payload asserting tasks columns land AND done issues land in `delivered_issues` (and NOT in `tasks` — assert `project.tasks.count` unchanged); stub the client with Minitest::Mock behind instance methods (**no new gems** — follow whatever stubbing pattern `test/services/` already uses).

- [ ] Steps: failing model/service tests → implement → `bin/rails db:migrate` → PASS → commit `feat: sync story points + delivered-issues mirror (400d window)`.

### Task 6.3: Auto-estimation engine + AI Estimate tab

**Files:**
- Create: `app/jobs/auto_estimate_job.rb`, `app/services/estimate_parser.rb`
- Modify: `app/services/jira_sync_service.rb` (post-sync trigger detection), `app/controllers/brief_commits_controller.rb` (briefed trigger), routes (`post "workshop/ideas/:id/estimate"` manual trigger)
- Create: `app/views/workshop/process/_estimate_tab.html.erb`
- Test: job test with stubbed CLI, parser unit test

**Engine:**
- `EstimateParser.extract(text)` → `<estimate>{"points": 8, "rationale": "…"}</estimate>`, Fibonacci-validated (reuse `BreakdownParser::FIBONACCI` constant — extract it to a shared module or reference directly).
- `AutoEstimateJob.perform(task_id)`: skip if `ai_estimate_points.present?` and `jira_updated_at` unchanged since `ai_estimated_at`; prompt (heredoc, persona "senior tech lead", context = ticket + current detail draft/brief + `features_summary`; instruction: single `<estimate>` block, no breakdown); run `ClaudeCliService#start_session` (non-streaming, same failure-marker guard as `PrReviewJob`); on success: save `ai_estimate_points/ai_estimated_at`, then for each configured field name resolve+cache Jira field id (`fetch_field_id`) and `set_number_field` — **never** write fields not in `estimation_field_names` ("Manual estimate fields are never touched.").
- Triggers (workspace.estimation_trigger): `sprint` — during `sync_sprint_assignments`, enqueue for tasks newly gaining a `sprint_id` on a non-design board sprint; `status` — during `sync_issues`, when `jira_status_name` transitions into `estimation_status_trigger`; `briefed` — in `BriefCommitsController#commit` success path; `manual` — button only. All enqueues idempotent-guarded.
- **Estimate tab UI:** left summary card (Board = project name, "Estimate when" = trigger label, "Writes to field(s)" chips, footer "Manual estimate fields are never touched. Configure in **Configuration → AI**."); right table TASK/TITLE/AI EST./MANUAL over pipeline+recently-estimated tasks (`ai_estimated_at DESC LIMIT 20`; MANUAL column = `story_points` or "—").

- [ ] Steps: parser test → job test (CLI stub returns `<estimate>` / garbage / auth-error) → trigger tests → UI → commit `feat: AI auto-estimation engine writing configured Jira fields`.

### Task 6.4: AI Alerts — models, scheduler, Discord webhooks, UI

**Files:**
- Create: `db/migrate/XXXX_create_alert_rules.rb`, `XXXX_create_discord_webhooks.rb`
- Create: `app/models/alert_rule.rb`, `app/models/alert_run.rb`, `app/models/discord_webhook.rb`, `app/services/discord_webhook_client.rb`, `app/services/alert_parser.rb`, `app/jobs/alert_rules_dispatch_job.rb`, `app/jobs/alert_rule_run_job.rb`
- Create: `app/controllers/workshop/alert_rules_controller.rb` (+ routes `resources :alert_rules, only: [:create, :destroy] do member { get :history }`), views `_alerts_tab.html.erb`, `_new_rule_modal.html.erb`, `_history_modal.html.erb` (history via turbo frame)
- Modify: `config/recurring.yml` — add `alert_rules_dispatch: { class: AlertRulesDispatchJob, schedule: "every 5 minutes" }` (production block)
- Test: model due-logic unit tests (the core!), run-job test with stubbed CLI + webhook, controller tests

**Schema:**

```ruby
create_table :alert_rules do |t|
  t.references :workspace, null: false, foreign_key: true
  t.references :project,   null: false, foreign_key: true
  t.string :name, null: false
  t.text   :prompt, null: false
  t.string :frequency, null: false, default: "daily" # daily|weekdays|mwf|weekly|hourly
  t.string :run_at_time                              # "HH:MM", nil for hourly
  t.references :discord_webhook, null: false, foreign_key: true
  t.boolean :active, null: false, default: true
  t.datetime :last_run_at
  t.timestamps
end
create_table :alert_runs do |t|
  t.references :alert_rule, null: false, foreign_key: true
  t.boolean :fired, null: false, default: false
  t.string  :summary
  t.text    :detail
  t.string  :status, null: false, default: "ok" # ok|error
  t.datetime :ran_at, null: false
  t.timestamps
end
create_table :discord_webhooks do |t|
  t.references :workspace, null: false, foreign_key: true
  t.string :channel_name, null: false   # "#dev-alerts"
  t.string :url, null: false
  t.timestamps
end
```
`DiscordWebhook has_many :alert_rules, dependent: :restrict_with_error` — Task 9.2's Remove button must surface "Webhook is used by {n} alert rules" instead of a 500 on the FK. (Optional, now that webhooks exist: the Task 5.3 design-request notification may post here when a webhook is configured — one line, best-effort, rescue-log.)

**Due logic** (`AlertRule#due?(now)` — unit-test all branches, Warsaw TZ):
- hourly → `last_run_at.nil? || last_run_at <= now - 55.minutes`
- else: today matches frequency (weekdays Mon–Fri, mwf Mon/Wed/Fri, weekly Mon, daily always) AND `now >= today at run_at_time` AND `last_run_at` before today's scheduled time.

**Run job:** builds a **board snapshot** (no MCP): for the rule's project — tasks with key/title/status/`jira_status_name`/assignee/`issue_type`/`sprint_name`/days-in-status (approx: `now - jira_updated_at` — document the approximation in the prompt), open PR summaries from `pr_reviews`; prompt: "You are a delivery-watchdog. Evaluate the condition below against the JSON snapshot. Reply with exactly one `<alert>{\"fired\": bool, \"summary\": \"…\", \"detail\": \"…\"}</alert>`. summary ≤ 90 chars." + rule prompt + snapshot JSON. CLI failure → `AlertRun(status: "error", summary: "Run failed")` and rule's chip shows red. If `fired` → `DiscordWebhookClient.post(webhook.url, content: "🔔 **#{rule.name}** — #{summary}\n#{detail}")` (Net::HTTP POST JSON `{content:}`; never raises).

**UI (copy verbatim, except the MCP sentence — see quirks list):** rules list card per mockup (name, `last` chip = latest run: "Sent · {summary}" green / "No condition met" green / "Not run yet" gray / red on error; italic "{prompt}"; schedule line; `{channel} · Discord`; "Last run {time}"; "View history"); "New rule" modal — intro copy adapted: "A scheduled prompt. On its schedule the AI inspects the live Jira board state and posts to the channel only if the condition is met." (NAME\*, WHAT TO WATCH FOR\* with placeholder "If more than 4 tasks have been in QA for longer than 3 days, send a notification." + hint "Write it as a condition — natural language is fine.", FREQUENCY select Daily/Weekdays/Mon, Wed, Fri/Weekly (Mon)/Every hour, TIME input disabled when hourly, NOTIFY CHANNEL chips from `discord_webhooks` — empty state links to Configuration → Integrations → Discord); history modal ("Fired {x} of {y} runs", timeline rows NOTIFIED/NO ACTION). Toast `Alert rule created · "{name}"`.

- [ ] Steps: due-logic unit tests first (≥8 cases) → parser/job tests → dispatch job test (enqueues only due+active) → controllers/UI → recurring.yml → full suite → commit `feat: AI alert rules — scheduler, Discord webhooks, history`.

---

# PHASE 7 — Reporting

### Task 7.1: Reporting query object + page

**Files:**
- Create: `app/services/workshop_report.rb` (pure read model, unit-testable), `app/controllers/workshop/reports_controller.rb`, `app/views/workshop/reports/show.html.erb`, partials `_metrics.html.erb`, `_trend_card.html.erb`, `_dev_table.html.erb`, `_delivered_table.html.erb`
- Create: `app/javascript/controllers/clar_trend_chart_controller.js` (Chart.js line/area, Clar-styled: indigo line, 8% fill, dashed crosshair via tooltip mode index, thinned x labels)
- Modify: routes (`get "reporting"`), sidebar flip
- Test: `test/services/workshop_report_test.rb` (the meat), thin controller test

**`WorkshopReport.new(project:, period:, developer: nil)` API** (all money in project currency; `period` = `:month` (current calendar month) or `:sprint` (active `JiraSprint` date window; fallback month)). **All "done"/delivered data reads `delivered_issues` (Task 6.2's mirror), never `tasks`:**
- `developers` — built from **HR data**: users with `time_entries` on the project in period (via `project.time_entries.completed.in_range`) UNION assignees in `delivered_issues` matched by email. Each: `{ user:, name:, sp:, bugs_fixed:, bugs_created:, hours:, cost_cents: }` where `sp` = Σ `delivered_issues.story_points` (`issue_type != 'Bug'`, `resolved_at` in period) by `assignee_email`; `bugs_fixed` = `delivered_issues` Bugs by assignee; `bugs_created` = `BugAttribution` count naming the user (lands in Phase 8 — until Task 8.2, fallback = Bugs reported by `reporter_email` across open `tasks` + `delivered_issues`); `hours` = completed time-entry seconds/3600.0; `cost_cents` = Σ `duration_seconds/3600.0 * hourly_rate_cents` (snapshot rate on entries — same rule as `TimeEntry#billable_amount`).
- `metrics` — features delivered (count + pts of delivered non-Bug issues in period), completed SP, new bugs (Bugs with `jira_created_at` in period — union of open `tasks` Bugs and `delivered_issues` Bugs), hours, cost. When a developer is focused, every metric scopes to them and the subs swap per mockup: "Completed (story points)" sub = dev's first name (else "across {n} developers"); "New bugs" = dev's created count, sub "created by {first}" (else "raised this period").
- `trend(granularity:, range:, developer: nil)` — months: last 6/12/24 calendar months of Σ story_points by `resolved_at` month (+ bugs created/fixed series for Phase 8 reuse); sprints: last 8/13/26 **closed+active** `JiraSprint`s of the project's boards, bucketing by `resolved_at BETWEEN sprint.start_date AND sprint.end_date`; each point `{label:, full:, sp:, bugs_created:, bugs_fixed:}`. When `developer` is present, filter by `assignee_email` — real per-dev data (a deliberate improvement over the mockup's `repShare` scaling hack; see quirks list).
- `delivered` — delivered non-Bug issues with points in period: key/title/dev(assignee)/pts/merged(resolved_at)/prs (count of `pr_reviews` whose stored `pr_branch`/`pr_title` contains the key via `PrJiraKey`-style regex — computed once per report).

**Ordering note:** Phase 7 before Phase 8 → `bugs_created` uses reporter fallback; Phase 8 Task 8.2 flips it to attributions. Both explicitly coded.

**UI:** controls (developer `clar-select` with avatar, period `clar-tabs` "{Month YYYY}" / "{active sprint name}"), 5 `clar-metric` cards (cost formatted with project currency), trend card ("Story points delivered over time", delta badge vs first visible point computed from the dev-scoped series, subtitle "{name}'s throughput per {gran}." when focused / "Team throughput per {gran}." otherwise + range label, granularity + range `clar-tabs` — GET params `gran`,`range`; **granularity tab links reset range to that granularity's default (months→12, sprints→13)** and the controller coerces `range` to the allowed set per granularity — {6,12,24} / {8,13,26} — falling back to the default), dev table + Team total row (hidden when a single dev focused), delivered table + empty state "No features delivered by {name|the team} this period." Subtitle "Hours & cost from internal time-tracking" verbatim. Money visible to all workshop members? **No** — respect `can_see_money?`: hide COST column + Project cost card from non-admins (D5).

- [ ] Steps: report unit tests with fixtures (SP bucketing, sprint windows, cost math, dev matching by email) → controller/view → chart controller (data via `data-clar-trend-chart-points-value` JSON) → PASS → commit `feat: Workshop reporting — throughput, cost, delivered`.

---

# PHASE 8 — Bug Reporting

### Task 8.1: BugAttribution model + analysis job

**Files:**
- Create: `db/migrate/XXXX_create_bug_attributions.rb`, `app/models/bug_attribution.rb`, `app/services/attribution_parser.rb`, `app/jobs/bug_attribution_job.rb`
- Modify: `app/services/jira_sync_service.rb` — post-sync: enqueue `BugAttributionJob` for newly-synced Bugs without an attribution (cap 3 per run to bound CLI cost)
- Test: parser + job tests (stubbed CLI)

```ruby
create_table :bug_attributions do |t|
  t.references :project, null: false, foreign_key: true
  t.string :jira_key, null: false        # attribution keyed by issue, survives the bug moving
  t.references :task, null: true, foreign_key: true   # from tasks (open) while it exists
  t.string :origin_kind   # new_functionality|existing_code
  t.string :author_name
  t.string :author_email
  t.string :confidence    # high|medium|low
  t.text   :reasoning
  t.string :status, null: false, default: "pending" # pending|done|failed
  t.datetime :analyzed_at
  t.timestamps
  t.index [:project_id, :jira_key], unique: true
end
```
(Keyed by `jira_key`, not a unique task ref: bugs get analyzed while open — rows in `tasks` — but once fixed they only exist in `delivered_issues`; the attribution must join both by key.)

Prompt (job heredoc): forensic engineer persona; input = bug ticket (key/title/description/created date); instructions: use `git log`, `git blame`, `grep` in the checkout to locate the defect origin; decide `origin_kind` (introduced by a recent feature vs long-standing code), attribute the most likely author, confidence high/medium/low, 1–3 sentence `reasoning` citing commits/files; output exactly one `<attribution>{JSON}</attribution>`. Failure markers → `status: "failed"` (retryable by a manual "Analyze" button).

- [ ] Steps: parser test → job test → sync hook test → commit `feat: AI bug-origin attribution (git-blame analysis)`.

### Task 8.2: Bug Reporting page

**Files:**
- Create: `app/controllers/workshop/bugs_controller.rb`, `app/views/workshop/bugs/show.html.erb`
- Modify: `app/services/workshop_report.rb` — `bugs_created` per dev now counts `BugAttribution` (author_email match, fallback name), plus `bug_stats` (`created_this_month`, `top_creator`, `top_fixer`) and the bugs trend reuses `trend`
- Modify: routes + sidebar flip
- Test: report additions + controller test

**UI (verbatim):** H1 "Bug Reporting", sub "Source: Jira issues of type **Bug**. The AI attributes origin from the code — and shows how sure it is."; 3 stat cards ("Bugs created · {Month}" warn number, "Created the most" name + "{n} bugs", "Fixed the most"); "Bugs over time" card — legend (Bugs created warn / Bugs fixed success), two-series chart (created filled), delta badge (down=green), same gran/range controls (shared params + the same reset/coercion rules as Reporting); "Bug analysis" list = recent Bugs **merged from open `tasks` and fixed `delivered_issues`** (by recency), joined to `bug_attributions` on `jira_key`: key, title, origin badge (`clar-badge-ai` "New functionality" / `clar-badge-muted` "Existing code"), attribution badge colored by confidence (low prefixes "Likely: "), star-icon reasoning box; pending rows show a subtle "Analyzing…" chip; failed rows an "Analyze" retry `button_to`.

- [ ] Steps: failing tests → implement → PASS → commit `feat: Bug Reporting — stats, trend, AI attribution list`.

---

# PHASE 9 — Configuration (admin)

### Task 9.1: Configuration page + AI tab settings

**Files:**
- Create: `db/migrate/XXXX_add_ai_settings_to_workspaces.rb` (`pr_review_prompt` text, `figma_read_enabled` boolean default false — `pr_poll_minutes`/`pr_polled_at` already landed in Task 6.1)
- Create: `app/controllers/workshop/configuration_controller.rb` (`show` `?tab=integrations|ai|users`, `update`), `app/views/workshop/configuration/show.html.erb`, `_integrations_tab.html.erb`, `_ai_tab.html.erb`, `_users_tab.html.erb`, manage-modal partials `_manage_github.html.erb`, `_manage_jira.html.erb`, `_manage_discord.html.erb`, `_manage_figma.html.erb`
- Modify: `app/jobs/pr_review_job.rb` — `build_prompt` uses `workspace.pr_review_prompt.presence || DEFAULT_PROMPT` (extract current heredoc to `DEFAULT_PROMPT` constant; seed the textarea with it). The check-job throttle on `pr_polled_at` already exists from Task 6.1 (cron stays `*/7` as the tick floor → effective interval `max(7, setting)`; UI hint "effective minimum 7 — the checker ticks every 7 minutes")
- Routes: `patch "configuration"`, `resources :discord_webhooks, only: [:create, :destroy]` (namespace)
- Test: controller tests (admin-gated 403 for employees; updates persist; check job honors interval — unit test the guard)

**UI (verbatim):** "ADMINISTRATOR ONLY" badge, H1, sub "Per-project credentials, AI behaviour and access. Hidden from Product Owners."; tabs.
**AI tab:** provider card ("Configurable dependency. Only Claude Opus is in scope today." + active row "Claude Opus · active" — read-only); PR review prompt card (mono textarea, default = extracted DEFAULT_PROMPT); polling interval card (big number + range slider 1–30, hint "effective minimum 7 — the checker ticks every 7 minutes"); Estimation target card (Board = project, field chips multi-select ≥1 from `["AI estimation","Story point estimate","T-shirt size","Confidence (1–5)"]` + free-add input, radio triggers with verbatim labels "Added to a Development sprint" / "Status changes to \"Ready for dev\"" / "AI actions = Briefed" / "Manually, on request"). Single `PATCH` form per card (auto-submit on change acceptable) with toast `{Section} settings saved`.

### Task 9.2: Integrations tab + manage modals

**Behavior:** four cards with live status/details:
- **GitHub** — status from `github_status_ok`; detail "{github_repo} · token ••••{last4} · checked {ago}"; modal: REPOSITORY (hint verbatim: "The repo is checked out server-side; master is refreshed daily."), ACCESS TOKEN (masked, write-only field — blank keeps; **Rotate** action = clears + focuses the field), DEFAULT BRANCH (display "master"), toggle "AI PR reviews on this repo" (`pr_review_enabled`), plus a read-only "Auto-refresh master daily" row showing the features-scan schedule + "Last refreshed {clar_time_ago(features_summary_updated_at)}" (the daily 05:00 `ProjectFeaturesScanJob` already does the refresh; the mockup's toggle is rendered as this informational row — flagged in D8); Test connection → existing `GithubClient#health_check` via new endpoint `post "configuration/test_github"` (do NOT reuse HR's `workspace_settings#test_github` route — duplicate the 5-line action to avoid touching HR).
- **Jira Cloud** — ENV-based single-tenant: status "Connected" if `JiraClient` configured (`ENV["JIRA_DOMAIN"].present?`); detail "{domain} · fields "AI estimation" ✓ "AI actions" ✓ · AI fields verified" (the mockup's "· MCP enabled" suffix is replaced — see quirks list; the "MCP access for AI Alerts" toggle is omitted); modal read-only fields + CUSTOM FIELDS check list (verify via cached field ids; "Verify fields" button resolves + caches `jira_ai_actions_field_id`, `jira_ai_estimation_field_id`, `jira_story_points_field_id`); hint "Credentials are configured on the server (.env)."
- **Discord** — status "{n} webhooks"; modal: webhook list (channel_name + Remove — destroy is blocked with toast "Webhook is used by {n} alert rules" when alert rules reference it, per Task 6.4's `restrict_with_error`), "+ Add webhook" (name + URL), OTHER CHANNELS Slack/Teams dashed "SOON" cards (static); note that reminder group-DM config stays in HR Workspace Settings untouched.
- **Figma** — status from `figma_read_enabled`; modal: explainer "Access is configured as an MCP server in the analysis checkout — this toggle only controls whether Details Gathering instructs the AI to read Figma frames." + toggle (consumed by refine/breakdown prompts: wrap the existing Figma instruction paragraphs in `if workspace.figma_read_enabled`).
- Modal footer: Test connection (github/jira only) / Cancel / Save changes, toasts verbatim.

### Task 9.3: Users tab

Read-only member list (avatar, name, email, role badge Administrator warn-style / Product Owner primary-style for employees with workshop access / "Client" muted) + **Invite** button → links to existing HR invite (`new_workspace_member_path`) in a new tab (HR screen unchanged) — or, if product switching friction matters, render a minimal duplicate invite form posting to a new `workshop/configuration#invite` that calls the same `WorkspaceMembership` creation path *without touching the HR controller*. Choose the link approach (D6 recommendation: link; zero duplication).

- [ ] Steps (all of Phase 9): failing controller tests → migrations → jobs honor settings → tabs/modals → PASS → commits per task 9.1/9.2/9.3.

---

# PHASE 10 — Ports, cleanup, rollout

### Task 10.1: Re-point legacy Workshop entries
- `WorkshopController#new_idea|start` → redirect to pipeline (modals replace them); keep `#brief` redirecting to `workshop_idea_path(task, stage: "briefing")` for old links. Delete `app/views/workshop/{index,new_idea,brief}.html.erb` + `idea_picker_controller.js` after redirects land. Update `product_landing_path` workshop branch → `workshop_pipeline_path` (shared concern — additive change of one path helper).
- Tests: redirect tests. Commit `chore: retire legacy workshop landing/new-idea/brief screens`.

### Task 10.2: Re-skin Jira Tasks board + breakdown page into the Clar shell
- These pages already got `layout "workshop"` in Task 1.2 (shell only). Now sweep their inner views: replace `m3-*` classes and inline `style=` colors with `clar-*` equivalents **without changing structure/behavior** (`index`, `_kanban`, `_list`, `_task_detail`, `show`, `task_breakdowns/show`, `_chat_panel`). Keep all Stimulus wiring identical. This is cosmetic; test = existing controller tests stay green + manual pass.
- Commit `feat: re-skin Jira Tasks board and breakdown page to Clar`.

### Task 10.3: Final sweep
- [ ] Run full suite `bin/rails test` — green.
- [ ] `git grep "m3-" app/views/workshop app/views/jira_tasks app/views/task_breakdowns` → zero hits.
- [ ] `git grep "style=\"color" app/views/workshop` → zero hits (design-direction memory).
- [ ] Verify HR: `git diff --stat main -- app/views/time_entries app/views/timesheets app/views/holiday_requests app/views/layouts/application.html.erb` → empty.
- [ ] Verify HR data surfaces: the Projects index task-count badges show the same numbers as before the redesign (done issues live in `delivered_issues`, never `tasks`), and HR timer-bar task search returns the same results.
- [ ] Confirm every migration ran on a MySQL database too (staging or a local mysql2 run) — dev/test Postgres passing is NOT sufficient.
- [ ] Delete `redesign.html` from repo root? **No** — leave it; it's the spec (untracked). Ask user before removing.
- [ ] Update `config/recurring.yml` comments; deploy notes: run migrations, verify schema (memory: deploy_push_first — push before `cap deploy`, verify schema after).
- [ ] Commit `chore: workshop redesign final sweep`.

---

## Open Decisions (recommendations pre-selected; confirm with user before the affected phase)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Pipeline access: admin-only (today) vs any member with `workshop_access` | Open to members ("Product Owner" in mock); Jira **writes** stay admin-gated? → simplest faithful reading: members can push too; keep `require_workshop!` workspace flag. Confirm. |
| D2 | Jira Tasks board in new nav (mock omits it) | Keep as a nav item — clients and the breakdown flow live there. |
| D3 | Details push for local-only ideas (mock fakes a key) | Require brief-push first (creates the issue); details push button disabled with tooltip until Jira-linked. |
| D4 | "Designers" — no designer role exists | Any workspace member selectable; no new role. |
| D5 | Money visibility in Reporting | Respect existing `can_see_money?` (admins only see COST/Project cost). |
| D6 | Config → Users invite | Link to existing HR invite screen; no duplication. |
| D7 | AI Estimate scope | Workspace-level settings (fields/trigger), per-project board label display only. |
| D8 | GitHub "Auto-refresh master daily" toggle | Render as a read-only info row (the daily features-scan job already refreshes; a real toggle would need a new per-workspace job gate — defer). |

## Execution order & shippability

Each phase is independently shippable and behind the Workshop product boundary: 1 (shell) → 2–3 (pipeline+intake) → 4–5 (workspace) → 6 (process) → 7 (reporting) → 8 (bugs) → 9 (config) → 10 (cleanup). Phases 6–9 are mutually independent after 6.2 (sync fields) — 7 and 8 both depend on Task 6.2; 8.2 depends on 7.1's `WorkshopReport`.

## Self-review checklist (run after writing each phase's code)

1. Spec coverage: every row of Reference A has a task — verified (rows 1–67 map to Tasks 1.1–10.2).
2. HR boundary: `git diff` against the do-not-touch list must be empty at every commit.
3. Copy fidelity: button labels/toasts/empty states match Reference A quotes.
4. No inline color styles; no `m3-*` inside `.clar-app`.
5. All AI outputs parsed via strict `<tag>` blocks with failure-marker guards; Jira writes via `{ok:, error:}` services.
