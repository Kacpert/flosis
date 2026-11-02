# Workshop Redesign — Deploy Notes & Final Sweep

## Status
All 28 tasks (Phases 1–10) of `docs/superpowers/plans/2026-07-03-workshop-redesign.md` are implemented on branch `feat/workshop-redesign`, each reviewed and Playwright-verified against `redesign.html`. Production untouched.

## Final sweep results (Task 10.3)
- ✅ Full suite: 729 runs, 4 failures — the SAME 4 pre-existing failures that were red on `production` before this branch (ClaudeCliService x3 [--add-dir flag / nil env], HolidayRequest cancelled-overlap). NONE introduced by the redesign. (Baseline was 5 at branch start; Task 6.2 fixed a flaky JiraSyncService mock, so baseline is now 4.)
- ✅ `git grep m3-` in app/views/{workshop,jira_tasks,task_breakdowns} → ZERO hits.
- ✅ `git grep 'style="color'` in app/views/workshop → ZERO hits (design-direction preference honored).
- ✅ HR boundary: `git diff production -- app/views/{time_entries,timesheets,holiday_requests} app/views/layouts/application.html.erb` + HR controllers → EMPTY. No HR file touched.
- ✅ HR data surface: `project.tasks.size` (Projects index badge) unaffected — done issues live in the separate `delivered_issues` mirror, never in `tasks`.

## ⚠️ MySQL portability — VERIFY AT DEPLOY (dev/test are Postgres; production is MySQL)
Every migration was written portable (no jsonb → :json; JSON defaults set in the MODEL not the DB, since MySQL JSON columns can't have DB defaults; no partial indexes; no ILIKE → LOWER LIKE; no window/DISTINCT-ON SQL — Ruby find_each backfills). But dev/test Postgres passing is NOT proof for MySQL. Before/at deploy:
1. Run all workshop migrations (20260703* — 12 of them) against a MySQL DB (staging or local mysql2).
2. Verify schema after (memory: deploy_push_first — push to the git REMOTE before `cap deploy`, verify schema after migrations).
New tables: pipeline cols on tasks, briefs/task_drafts versioning, design_requests, delivered_issues, estimation settings, bug_attributions, alert_rules/alert_runs/discord_webhooks, AI/figma settings on workspaces.

## recurring.yml
Added `alert_rules_dispatch` (AlertRulesDispatchJob, every 5 min) to the production block. PR-review check cron unchanged (*/7 tick floor; effective interval max(7, pr_poll_minutes)).

## Open items flagged for review (decisions I made while you were away; confirm or override)
1. **Refine-chat client access** (Task 5.1): the shared /jira_tasks refine chat stays client-accessible by long-standing design (documented in chat_sessions_controller.rb). Clients can't reach the Workshop UI; injected brief content is their own project data. Alternatives: block clients entirely (regresses the Jira Tasks board feature) or block only pipeline tasks (adds coupling). CHOSEN: leave-as-is + documented.
2. **Verification was LOCAL only** (Playwright vs redesign.html, externals stubbed) per your confirmation — no production-server testing, no real Jira task created.
3. `redesign.html` left in repo root (it's the spec, untracked) — not deleted per the plan; remove if you want.

## Minor follow-ups logged (non-blocking, in .superpowers/sdd/progress.md)
- Rich-text HTML versions render escaped in _brief_history_modal / _reset_modal / legacy brief view (display-only; apply _document_panel's HTML-detect+sanitize branch).
- Unanalyzed bugs (no BugAttribution row) render bare on Bug Reporting (no "Analyze" affordance — only failed rows have it).
- gran/range coercion duplicated between ReportsController and BugsController.
- A few tint-buttons on the Jira board use clar-badge-*/clar-btn-primary with their own shape utilities (render fine, not normalized).
