# AI PR Reviewer — Design

**Date:** 2026-06-14
**Status:** Approved, ready for implementation plan

## Problem

We want an automated reviewer that watches a GitHub repo and leaves a small
number of high-value review comments on pull requests, informed by the linked
Jira ticket, the codebase, and git history.

## Hard architectural constraint

The reviewer runs as a **recurring Solid Queue job on the server**. Server jobs
are plain Ruby and have **no access to MCP** (GitHub MCP is session-only). So:

- **GitHub access:** direct **REST API** via `Net::HTTP` (pattern of `JiraClient`).
- **AI reasoning:** the existing **`claude` CLI** (`ClaudeCliService` pattern)
  pointed at a **local checkout** of the repo, so the AI can read files and run
  `git log`/`git blame` for history.

MCP is NOT used anywhere in this module.

## Scope & rules

- **One configured repo** per workspace (e.g. `RubyOnSaas-wiki/clar`).
- Review **open, non-draft** PRs only (skip drafts, closed, merged).
- **Jira link:** detect a key (e.g. `DEV-836`, case-insensitive) in the PR
  branch name, title, or body; match `Task.find_by(external_reference:)`. If no
  key/Task, review anyway without ticket context.
- **Cadence:**
  - First time a PR is seen → **initial** review, **max 4** inline comments.
  - On **new commits** since the last review → **followup** review of just the
    new commits, **max 2** inline comments.
  - Unchanged PRs are skipped. No re-reviewing unchanged code. No repeated
    commenting beyond new-commit follow-ups.
- **Comment caps are enforced in code**, not just requested in the prompt.
- **No issues found →** post a tiny `🤖 No issues found 👍` review (still
  records the reviewed SHA so it isn't re-reviewed).
- **Posting identity:** uses the user's personal GitHub token, so reviews appear
  under their account; every review body is prefixed `🤖 Automated AI review`
  so the team knows it's automated.
- **Schedule:** check every **7 minutes, 09:00–20:00 Warsaw**, weekdays and
  weekends (PRs happen any day). The 7-min check only *triggers the AI* when a
  new or changed PR exists (saves CLI cost).

## Configuration (Workspace Settings, admin-only)

Add columns to `workspaces` (reusing the Discord-settings UI pattern):

- `github_token` (string) — personal access token; masked field, blank = keep.
- `github_repo` (string) — `owner/repo`.
- `pr_review_enabled` (boolean, default false) — opt-in toggle.
- `github_status_ok` (boolean, nullable) — last health-check result.
- `github_status_checked_at` (datetime, nullable) — when it was last checked.
- `github_status_error` (string, nullable) — short failure reason for display.

Stored plaintext in the DB (same accepted caveat as the Discord token). Token
needs `repo` scope (read PRs/contents + post reviews).

## Connection health & status indicator

So the user can tell at a glance whether the reviewer actually works:

- **Health check:** `GithubClient#health_check` does a cheap authenticated call
  (`GET /repos/{repo}`) and returns `{ ok:, error: }`. It runs (a) at the start
  of every `PrReviewCheckJob` run and (b) on demand via a **"Test connection"**
  button in settings. Each run writes `github_status_ok`,
  `github_status_checked_at`, and `github_status_error` on the workspace.
- **Indicator (Workspace Settings):** a green dot + "Connected (checked Xm ago)"
  when `github_status_ok`; a red dot + the error reason when not; grey/"not
  checked yet" when null.
- **Persistent error banner (admin-only, app-wide):** when a `github_token` is
  present AND `github_status_ok == false`, show a red banner on every page for
  admins/owners (rendered in the layout, like the impersonation banner),
  e.g. *"⚠️ GitHub PR reviewer can't reach GitHub: \<error\>. Check the token in
  Workspace Settings."* Employees/clients never see it. No token set → no
  banner (feature simply not in use). Healthy → no banner.
- A helper `github_connection_problem?` (workspace) = token present &&
  `github_status_ok == false`; exposed as a `helper_method` for the layout.

## Components

### 1. `GithubClient` — `app/services/github_client.rb`
`Net::HTTP` wrapper. Base `https://api.github.com`. Headers:
`Authorization: Bearer <token>`, `Accept: application/vnd.github+json`,
`X-GitHub-Api-Version: 2022-11-28`, a `User-Agent`.

- `self.for(workspace)` → builds from `github_token` + `github_repo`.
- `configured?` → token and repo present.
- `open_pull_requests` → `GET /repos/{repo}/pulls?state=open` (returns array;
  caller filters out `draft == true`).
- `pull_request(number)` → `GET …/pulls/{n}` (for head SHA, body, title).
- `pull_request_commits(number)` → `GET …/pulls/{n}/commits`.
- `pull_request_files(number)` → `GET …/pulls/{n}/files` (diff/patch per file).
- `create_review(number, body:, event:, comments:)` →
  `POST …/pulls/{n}/reviews` with `event: "COMMENT"` and `comments: [{path,
  line, side:"RIGHT", body}]`. Returns true on 2xx; logs + returns false on
  error; never raises.
- `health_check` → `GET /repos/{repo}`; returns `{ ok: true }` on 2xx, else
  `{ ok: false, error: "<status/message>" }` (e.g. "401 Unauthorized",
  "404 repo not found", "connection refused"). Never raises.

All requests time out and rescue `Net::OpenTimeout, Net::ReadTimeout,
SocketError, Errno::ECONNREFUSED` (JiraClient pattern).

### 2. `PrReview` model + table `pr_reviews`
One row per (workspace, pr_number) tracking review state.

Columns: `workspace_id` (FK), `pr_number` (integer), `last_reviewed_sha`
(string), `initial_done` (boolean, default false), `reviewed_at` (datetime),
timestamps. Unique index `[workspace_id, pr_number]`.

`belongs_to :workspace`.

### 3. `PrReviewCheckJob` — `app/jobs/pr_review_check_job.rb` (recurring)
- No-op unless within 09:00–20:00 Warsaw (defensive; the cron also bounds it).
- For each workspace with `pr_review_enabled` and a configured `GithubClient`:
  - **Health check first:** run `health_check`, persist `github_status_ok`,
    `github_status_checked_at`, `github_status_error`. If not ok, skip this
    workspace's PR scan this cycle (the banner will surface the problem).
  - List open PRs, drop drafts.
  - For each PR, read head SHA (`pull_request` payload `head.sha`).
  - Look up `PrReview` for (workspace, pr_number):
    - none → enqueue `PrReviewJob.perform_later(workspace_id, pr_number, "initial")`.
    - exists and `last_reviewed_sha != head_sha` → enqueue `…, "followup"`.
    - exists and SHA unchanged → skip.

### 4. `PrReviewJob` — `app/jobs/pr_review_job.rb` (one per PR)
- Reload PR; bail if it's now draft/closed.
- Resolve Jira key from branch/title/body → optional `Task` context (summary,
  description, acceptance criteria text if present).
- Gather diff context:
  - initial → all changed files' patches.
  - followup → only files/commits new since `last_reviewed_sha`
    (via `pull_request_commits` filtered to after the recorded SHA, and their
    file patches).
- Run the `claude` CLI against the local checkout with a prompt containing: the
  Jira context (or "no linked ticket"), the diff, and rules — *return JSON: an
  array of at most N items `{path, line, comment}`, each the MOST important
  issue (correctness, security, missed acceptance criteria, data integrity);
  skip style nits; return `[]` if nothing important. Comments must reference
  real changed lines.*
- Parse JSON; **cap to 4 (initial) / 2 (followup)** in code.
- Post one review via `create_review`:
  - with comments → `body: "🤖 Automated AI review"`, the inline `comments`.
  - empty → `body: "🤖 No issues found 👍"`, no inline comments.
- Upsert `PrReview`: set `last_reviewed_sha = head_sha`, `initial_done = true`,
  `reviewed_at = Time.current`.

### 5. Settings "Test connection"
A `WorkspaceSettingsController#test_github` action (admin-only, `POST
/workspace_settings/test_github`): runs `GithubClient.for(current_workspace)
.health_check`, persists the three status fields, redirects back to settings
with a flash showing the result. Lets the admin verify a freshly-saved token
without waiting for the next 7-min cycle.

### Scheduling — `config/recurring.yml`
```yaml
  pr_review_check:
    class: PrReviewCheckJob
    schedule: "*/7 9-19 * * *"
```
(`9-19` covers 09:00–19:59; combined with the in-job 20:00 cutoff this yields
checks from 09:00 through ~19:59, i.e. the 9 AM–8 PM window. Evaluated in the
app's Warsaw zone.)

## Error handling

- Unconfigured / disabled workspace → job no-ops.
- GitHub or claude CLI failure for one PR → logged, that PR skipped, others
  continue; `PrReview` is only updated after a successful post so a failed PR is
  retried next cycle.
- Malformed AI JSON → treated as "no parsable issues"; logs and posts nothing
  for that run (does NOT advance the SHA, so it retries next cycle), to avoid
  silently marking a PR reviewed when the AI step failed.

## Testing (Minitest, WebMock for HTTP, claude CLI stubbed)

- `GithubClient`: builds correct requests (auth/accept headers, endpoints);
  parses PR list; `create_review` posts the right JSON; `configured?`;
  network failure returns false without raising; `health_check` returns
  `{ok:true}` on 200 and `{ok:false, error:…}` on 401/404/network error.
- Jira-key detection: extracts `DEV-836` from branch, title, body; nil when
  absent; case-insensitive.
- `PrReviewCheckJob`: enqueues initial for an unseen PR; followup when head SHA
  changed; skips unchanged; skips drafts; no-op when disabled/unconfigured;
  no-op outside the 09–20 window.
- `PrReviewJob`: caps comments to 4 (initial) / 2 (followup); posts review with
  parsed inline comments (GithubClient stubbed); posts the "no issues" review on
  empty; records `last_reviewed_sha`/`initial_done`; does not advance SHA on AI
  parse failure.
- Settings controller: admin can save `github_token`/`github_repo`/toggle;
  blank token keeps existing; employee blocked.
- Health/status: `PrReviewCheckJob` persists status fields and skips the scan
  when unhealthy; `test_github` action updates status and is admin-only.
- Banner: `github_connection_problem?` true only when token present + last check
  failed; layout shows the red banner for admins in that case and hides it when
  healthy, when no token, or for non-admins.

## Out of scope

- Multiple repos; webhooks/real-time (polling only); reviewing drafts;
  approving/requesting-changes (always `event: COMMENT`); MCP.
