# Per-Project MCP Workspaces — Design

**Date:** 2026-08-07
**Status:** Approved (design), pending implementation plan
**Author:** Kacper + Claude

## Problem

AI Alerts & Automations (`AlertRuleRunJob`) run Claude via `ClaudeCliService`
with `mcp__github__*` / `mcp__jira__*` tools **allowlisted** but no MCP servers
actually connected in the job environment. A live run reported it "could do no
work": no GitHub MCP server, no Jira MCP server, `gh` not installed, and the
non-interactive session couldn't be granted approval. Only `figma` (stdio, in
`~/.claude.json`) and the interactively-authenticated claude.ai remote servers
are connected — none usable for the translation-scan automation.

Separately, we are onboarding external clients who have their **own** Jiras and
repos. Today Jira site/email/token live in a single global server `.env`, and the
codebase checkout is a single shared `~/work/elvium`. This does not scale to
multiple clients.

## Goal

Onboarding a new client with their own Jira and repo "just works": configure the
integration in the UI, and the AI automations gain working, project-scoped
GitHub + Jira MCP tools. Each project is isolated on the server with its own
folder, repo checkout, and generated `.mcp.json`.

**Non-goal / must-not-break:** the existing `PrReviewJob` (app-side
`GithubClient`, not MCP) and the existing single `~/work/elvium` checkout must
keep working unchanged. The legacy HR system (Workspace-level creds) is
to-be-removed later; we do not refactor it, we only avoid breaking it.

## Current State (verified)

- **GitHub creds** are per-**Workspace**, plaintext DB columns
  (`workspaces.github_repo`, `workspaces.github_token`). `GithubClient.for(ws)`
  reads them. Not encrypted.
- **Jira creds**: site/email/token come from **ENV**
  (`JIRA_DOMAIN`/`JIRA_EMAIL`/`JIRA_API_TOKEN`); only the Jira **project key** is
  per-project (`projects.external_reference`, with `external_type == "jira"`).
  Only the 3 custom-field IDs are per-Workspace DB columns. `JiraClient.new` is
  always called with no args → always ENV.
- **No encryption** anywhere (`grep encrypts app/models` → nothing).
- **Checkout path is global**: `~/work/elvium` (via `PR_REVIEW_CODEBASE_PATH` /
  `ClaudeCliService::DEFAULT_CODEBASE_PATH`), refreshed daily 05:00 by
  `ProjectFeaturesScanJob#pull_latest!`. Never derived from a project/workspace.
- **`ClaudeCliService`** chooses `codebase_path` as arg → `CHAT_CODEBASE_PATH`
  → default; `chdir`s there. Never per-project.
- **Server environment**: `node`/`npx` present (node v20); `python3` 3.9 + `pip3`
  present; **no `uvx`**, **no docker**. `claude` CLI v2.1.220 supports
  `--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `--permission-mode`.
  `@modelcontextprotocol/server-github` runs via npx (deprecated but functional).
  `mcp-atlassian` (sooperset, Python) exposes the generic `jira_get`/`jira_post`
  tools that match our existing allowlist — requires `pip3 install`.
- **Unused `Integration` model** (`provider` + jsonb `config`) exists but is not
  wired into any cred flow. We do NOT use it; creds go on `projects` as columns.

## Architecture

Each **Project** owns an isolated server-side folder containing its repo
checkout(s) and a generated `.mcp.json` wiring `github` + `jira` stdio MCP
servers to that project's own credentials. AI automations run Claude with
`chdir` into that folder and `--mcp-config <folder>/.mcp.json
--strict-mcp-config`, so the AI has real, project-scoped tools and cannot see
other projects' servers or the global figma server.

**Two worlds coexist deliberately:**
- **Legacy (unchanged):** `PrReviewJob` uses app-side `GithubClient` against
  `~/work/elvium`. Zero regression risk.
- **New:** `AlertRuleRunJob` uses the per-project folder + MCP. The `elvium`
  project is grandfathered onto its existing `~/work/elvium` checkout; new
  client projects get an app-cloned folder.

**Credential resolution order** (single rule, one place):
`Project → Workspace → ENV`. Projects get their own (encrypted) cred columns; if
blank, fall back to the Workspace (keeps HR/legacy working); Jira additionally
falls back to ENV during the transition.

## Data Model

New columns on **`projects`** (secrets via Rails `encrypts`; all nullable, no
backfill):

| Column | Type | Encrypted | Purpose |
|---|---|---|---|
| `github_repo` | string | no | e.g. `elviumcom/elvium` |
| `github_token` | string | **yes** | project's PAT |
| `jira_site` | string | no | e.g. `elvium.atlassian.net` |
| `jira_email` | string | no | Jira account email |
| `jira_api_token` | string | **yes** | Jira API token |
| `workspace_dir` | string | no | absolute path to the project's folder |
| `repo_checkout_status` | string | no | `pending`/`cloning`/`ready`/`error` |
| `repo_checkout_error` | string | no | last clone/pull error |
| `mcp_synced_at` | datetime | no | when `.mcp.json` was last written |

Jira **project key** stays on `projects.external_reference` — unchanged.

**Encryption prerequisite (deploy):** `ActiveRecord::Encryption` keys
(`primary_key`, `deterministic_key`, `key_derivation_salt`) must be present in
Rails credentials / ENV on the server before the encrypted columns are used.
This is a one-time setup step, listed under Deployment Prerequisites.

**Migration safety:** all new columns nullable, no backfill. The `elvium` project
row leaves creds blank → resolver falls back to Workspace/ENV → behaves exactly
as today. Deploy breaks nothing.

## Components

### `ProjectCredentials` (new, `app/services/project_credentials.rb`)

The single place that answers "what creds does this project use". Consumed by the
`.mcp.json` generator, `GithubClient`, and `JiraClient`.

```
github_repo    → project.github_repo    || project.workspace.github_repo
github_token   → project.github_token   || project.workspace.github_token
jira_site      → project.jira_site      || ENV["JIRA_DOMAIN"]
jira_email     → project.jira_email     || ENV["JIRA_EMAIL"]
jira_api_token → project.jira_api_token || ENV["JIRA_API_TOKEN"]
jira_key       → project.external_reference
```

- `github_configured?` → repo && token both resolve.
- `jira_configured?` → site && email && token all resolve.

`GithubClient` gains `GithubClient.for_project(project)` (resolver-backed)
alongside the existing `GithubClient.for(workspace)`. `JiraClient` call sites for
automations instantiate with resolved per-project creds instead of bare
`JiraClient.new`. (Legacy HR/PR-review call sites are left as-is.)

### `ProjectMcpConfig` (new, `app/services/project_mcp_config.rb`)

Owns the folder + `.mcp.json` lifecycle.

- `write!(project)`:
  1. Ensure `workspace_dir` exists, `chmod 700`, app-user owned.
  2. Render JSON from `ProjectCredentials`. A server block is **omitted** if its
     creds don't resolve (half-configured project still yields a valid file).
  3. Atomic write (temp file + rename), `chmod 600`.
  4. Set `mcp_synced_at`.
- `path_for(project)` → the `.mcp.json` path for `--mcp-config`.

**Folder layout:**
```
~/work/clients/<workspace-id>/<project-id>/
├── .mcp.json          # chmod 600 — generated, gitignored, decrypted tokens
└── <repo-name>/       # git checkout, e.g. elvium/
```
Folder `chmod 700`, app-user owned. Multi-repo ready (several checkouts can sit
side-by-side later without redesign).

**`.mcp.json` shape** (server keys MUST be exactly `github` / `jira` so tool
names are `mcp__github__*` / `mcp__jira__*`, matching `AUTOMATION_TOOLS`):
```json
{
  "mcpServers": {
    "github": {
      "type": "stdio", "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "<resolved github token>" }
    },
    "jira": {
      "type": "stdio", "command": "mcp-atlassian",
      "env": {
        "JIRA_URL": "https://<resolved jira_site>",
        "JIRA_USERNAME": "<resolved jira_email>",
        "JIRA_API_TOKEN": "<resolved jira_api_token>"
      }
    }
  }
}
```

**Security note:** MCP stdio servers need the *decrypted* token in `.mcp.json`
on disk (inherent to the pattern — figma's key is already plaintext in
`~/.claude.json`). Mitigations: folder `700`, file `600`, app-user owned,
`.gitignore`d, never committed. No worse than the existing figma setup.

### `ProjectRepoCheckoutJob` (new)

Enqueued when GitHub integration is saved.
- No checkout yet → `git clone https://<token>@github.com/<repo>.git` into the
  folder.
- Checkout present → `git pull --ff-only`.
- Tracks `repo_checkout_status` / `repo_checkout_error`; surfaced in the Manage
  GitHub modal.

**Legacy elvium grandfathering (explicit):** the `elvium` project has
`workspace_dir` set explicitly to `~/work/elvium` (one-time DB setting) and is
**not** re-cloned. New projects get `workspace_dir` auto-assigned on GitHub save
and go through the clone flow.

### `ClaudeCliService` changes

- New optional `mcp_config:` param. When present, `build_command` adds
  `--mcp-config <path> --strict-mcp-config`.
- `--strict-mcp-config` ensures the run sees ONLY that project's servers
  (isolation from figma / other projects).
- **`codebase_path` for automations = the repo checkout subfolder**
  (`<workspace_dir>/<repo-name>`), not the parent `workspace_dir`, so Claude's
  Read/Grep/git operate inside the actual code. The `.mcp.json` lives in the
  parent `workspace_dir`; `--mcp-config` takes its absolute path, so the two can
  differ without issue. (Legacy elvium: `codebase_path` stays `~/work/elvium`.)
- No `--dangerously-skip-permissions`: the MCP tools are already in
  `AUTOMATION_TOOLS` via `--allowedTools`, and with servers now actually
  connected, `-p` runs them without interactive approval. This fixes the
  "approval cannot be granted" failure.

### `AlertRuleRunJob` changes (per run)

1. Resolve `project` from the rule → `ProjectCredentials`.
2. `ProjectMcpConfig.write!(project)` (regenerate → self-heal a stale/missing
   file; DB is source of truth).
3. Spawn `ClaudeCliService.new(codebase_path: <repo checkout subfolder>,
   mcp_config: ProjectMcpConfig.path_for(project), allowed_tools:
   ClaudeCliService::AUTOMATION_TOOLS)` (see the `codebase_path` note under
   `ClaudeCliService changes`).
4. Existing `<alert>` / `<memory>` / `<issues>` handling unchanged.

### Configuration UI changes

- **Manage Jira** modal becomes editable: Site URL, Email, API token (password
  field, blank-preserves-current), keeps Project Key + Verify fields. Saving
  writes the (encrypted) project columns and calls `ProjectMcpConfig.write!`.
  "Credentials configured on server" note is removed for projects that set their
  own creds.
- **Manage GitHub** modal unchanged in shape; save now also enqueues
  `ProjectRepoCheckoutJob` and calls `ProjectMcpConfig.write!`. GitHub creds
  move to the project columns (with Workspace fallback for legacy).
- Strong params extended for the new project cred fields; blank token preserves
  the existing encrypted value (same pattern as `github_token` today).

## Generation Triggers (source of truth = DB)

1. **On integration save** — saving GitHub or Jira in Configuration calls
   `ProjectMcpConfig.write!` for the current project.
2. **Before each run** — `AlertRuleRunJob` calls `write!` right before spawning
   Claude. A deleted/stale file self-heals from the DB.

## Error Handling (layered, degrades gracefully)

- **No creds resolve** → don't spawn Claude; record an `<issues>`-style note
  ("GitHub/Jira not configured for this project") visible in the Memory modal.
  No crash.
- **Repo clone fails** → `repo_checkout_status = error` + message in Manage
  GitHub modal; the automation still runs (AI reads PRs via GitHub MCP even
  without a local checkout).
- **MCP server fails to start / bad token** → the AI reports it in `<issues>`
  (already proven behavior). It now has real servers to succeed with.
- **`mcp-atlassian` not installed** → the run's `<issues>` surfaces a spawn
  error; a lightweight "Test connection" in the Jira Manage modal hits the
  resolved creds to catch this early.

## Deployment Prerequisites

1. `pip3 install mcp-atlassian` on the server (one-time; ideally a Capistrano
   step). `.mcp.json` invokes the `mcp-atlassian` command.
2. **Solid Queue PATH:** the job process must be able to spawn `mcp-atlassian`
   and `npx`. Ensure `$HOME/.local/bin` (pip user-install bin) and the node bin
   are on the Solid Queue process PATH, OR pin absolute command paths in
   `.mcp.json`. To be finalized in the plan.
3. `ActiveRecord::Encryption` keys present in Rails credentials / ENV on the
   server (for the encrypted columns).
4. `~/work/clients/` base dir writable by the app user.

## Testing

- `ProjectCredentials` — full fallback matrix (project/workspace/env, per field)
  and the `*_configured?` predicates.
- `ProjectMcpConfig` — correct JSON, omits servers with unresolved creds,
  600/700 perms, atomic write, self-heal on missing file.
- `ClaudeCliService#build_command` — includes `--mcp-config
  --strict-mcp-config` only when `mcp_config:` given.
- `AlertRuleRunJob` — calls `write!` before spawning, passes right paths,
  degrades when creds missing.
- Config controller — new Jira strong params, encrypted round-trip, enqueues
  checkout job, blank-token-preserves.
- **pg-gem caveat:** the local Mac segfaults running the suite; verify on the
  server (MySQL) + targeted unit runs where feasible.

## Out of Scope (future)

- Migrating `PrReviewJob` / `~/work/elvium` onto the new per-project model.
- Migrating existing plaintext `github_token` / `discord_user_token` to
  `encrypts`.
- Multi-repo-per-project UI (layout supports it; UI is single-repo for now).
- Removing the HR system.
