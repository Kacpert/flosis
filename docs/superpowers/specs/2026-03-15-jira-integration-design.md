# Jira Integration for Task Syncing

## Overview

Connect Gold projects to Jira projects so that Jira issues are synced as local Task records. The timer bar description field becomes a fuzzy-searchable dropdown showing synced tasks when a Jira-connected project is selected. Background sync via Solid Queue keeps tasks fresh (every 15 minutes), with a manual refresh option.

## Credentials

Stored in `.env` file (dotenv is already a transitive dependency — no gem addition needed).

Variables:
- `JIRA_DOMAIN` — e.g., `elvium.atlassian.net`
- `JIRA_EMAIL` — e.g., `kacper@rubyonsaas.com`
- `JIRA_API_TOKEN` — API token from Jira

A `.env.example` file will be created as a template (not committed with real values). The `.env` file must be in `.gitignore`.

Note: This is application-wide configuration. Multi-workspace Jira support (per-workspace credentials via Integration model) can be added later if needed.

## Jira API Client

**File:** `app/services/jira_client.rb`

Thin wrapper around Jira Cloud REST API v3. Uses Basic Auth (`email:api_token`) via `Net::HTTP`.

Methods:
- `fetch_projects` — returns list of Jira projects (key, name, id)
- `fetch_issues(project_key)` — returns issues for a project with key, summary, statusCategory, assignee email, URL. Handles pagination (Jira defaults to 50 per page, max 100). Filters to open issues only by default (`statusCategory != Done` in JQL) to avoid pulling thousands of closed issues.
- All API calls have a 10-second timeout
- Returns `nil` / empty array on failure (network errors, invalid credentials) — callers handle gracefully
- Errors logged via `Rails.logger.warn`

Uses Jira's `statusCategory.key` field (always one of `"new"`, `"indeterminate"`, `"done"`) rather than status name strings for reliable mapping.

## Project-Jira Mapping

Uses existing schema fields:
- `projects.external_reference` — stores Jira project key (e.g., "ELV")
- `projects.external_type` — set to `"jira"`

**Project form changes:**
- Add a "Jira Project" dropdown below existing fields
- Dropdown fetches Jira projects live via `GET /jira/projects` endpoint
- Selecting a Jira project sets `external_reference` and `external_type`
- Include blank option ("No Jira project") to disconnect
- Dropdown loaded via Stimulus controller (`jira-project-select`) that fetches options on connect
- Shows loading state while fetching; shows "Could not connect to Jira" on failure
- Helper method on Project: `jira_connected?` → `external_type == "jira"`

## Task Syncing

**File:** `app/services/jira_sync_service.rb`

For each Jira-connected project:
1. Fetch issues from Jira API for that project key (paginated, open issues by default)
2. For each issue, **find by `external_reference` + `external_type`** (NOT by name — avoids unique constraint issues on `project_id + name`):
   - `name`: `"ELV-42 Fix login page"` (key + summary) — updated on each sync
   - `external_reference`: Jira issue key (`"ELV-42"`)
   - `external_type`: `"jira"`
   - `external_url`: direct link to Jira issue
   - `assignee_email`: Jira assignee's email (new column)
   - `status`: `active` for statusCategory `new`/`indeterminate`, `done` for statusCategory `done`
3. Existing local tasks without `external_type: "jira"` are NOT touched (stand-ups, retros, etc.)
4. Previously synced tasks whose Jira issues are resolved get marked `done`
5. Jira issues that are deleted: synced tasks are left as-is (they may have time entries). They simply won't appear in future syncs and will age out naturally.

**Name collision handling:** If updating a synced task's name would violate the unique constraint (two Jira issues with same composite name), append the issue key to disambiguate.

## Migration

Add `assignee_email` column to `tasks` table:
```ruby
add_column :tasks, :assignee_email, :string
```

## Background Job

**File:** `app/jobs/jira_sync_job.rb`

- Solid Queue recurring job, every 15 minutes
- Iterates all projects where `external_type = 'jira'`
- Calls `JiraSyncService.new(project).sync` for each
- Manual trigger: `POST /projects/:id/jira_sync` (admin only)

**Recurring schedule** in `config/recurring.yml`:
```yaml
production:
  jira_sync:
    class: JiraSyncJob
    schedule: every 15 minutes
```

## Timer Bar — Fuzzy Search Dropdown

**Approach:** Extend the existing `combobox_controller.js` pattern but create a new `jira-task-search` controller since the behavior differs significantly: it fetches data from an API endpoint, has custom sorting (assigned-to-me first, status-based), renders status badges, and operates on the description field rather than replacing a select element.

**File:** `app/javascript/controllers/jira_task_search_controller.js`

**All three description field contexts** in the timer bar need this behavior:
1. Running timer form (line 10 — `time_entry[description]`)
2. Start timer form (line 58 — `:description`)
3. Manual entry form (line 112 — `time_entry[description]`)

When a Jira-connected project is selected and user focuses the description field:

1. Fetch tasks for the selected project from `GET /projects/:id/jira_tasks` (returns JSON, **sorted server-side**)
2. Show a dropdown below the description input
3. Fuzzy search filters as user types (client-side, simple substring scorer)
4. **Server-side sort order** (avoids exposing user email to JS):
   - Assigned to current user first
   - Then by status: In Progress (`indeterminate`) > To Do (`new`) > other
   - Then alphabetically
5. Each dropdown item shows: issue key (bold), summary, status badge
6. Selecting a task: fills description with task name, sets hidden `task_id`, closes dropdown
7. User can still type freely without selecting (for ad-hoc descriptions)
8. ESC or clicking outside closes dropdown
9. **The existing Task dropdown is hidden** when a Jira-connected project is selected (avoids redundancy — users would see the same tasks in both places)

For non-Jira projects: no dropdown on description field, existing Task dropdown shown as-is.

## New API Endpoints

| Method | Path | Controller#Action | Auth | Purpose |
|--------|------|-------------------|------|---------|
| GET | `/jira/projects` | `jira#projects` | `require_admin!` | List Jira projects for mapping dropdown |
| POST | `/projects/:id/jira_sync` | `jira#sync` | `require_admin!` | Manual sync trigger |
| GET | `/projects/:id/jira_tasks` | `jira#tasks` | `require_employee!` | JSON task list for fuzzy dropdown (sorted server-side) |

All endpoints include `WorkspaceScoped` concern. Project lookups scoped to `current_workspace.projects`.

## Files to Create/Modify

### New files:
- `app/services/jira_client.rb`
- `app/services/jira_sync_service.rb`
- `app/jobs/jira_sync_job.rb`
- `app/controllers/jira_controller.rb`
- `app/javascript/controllers/jira_task_search_controller.js`
- `app/javascript/controllers/jira_project_select_controller.js`
- `db/migrate/TIMESTAMP_add_assignee_email_to_tasks.rb`
- `.env.example`
- `test/services/jira_client_test.rb`
- `test/services/jira_sync_service_test.rb`
- `test/controllers/jira_controller_test.rb`

### Modified files:
- `app/views/projects/_form.html.erb` — add Jira project dropdown
- `app/views/shared/_timer_bar.html.erb` — wire all 3 description fields to jira-task-search controller, hide Task dropdown for Jira projects
- `config/routes.rb` — add jira routes
- `config/recurring.yml` — add jira_sync job
- `app/models/project.rb` — add `jira_connected?` helper
- `app/models/task.rb` — add scopes for jira tasks
- `.gitignore` — ensure `.env` is listed

## Data Flow

```
Jira Cloud API
     | (every 15 min + manual trigger)
     v
JiraSyncJob -> JiraSyncService -> Task records (external_type: "jira")
                                       |
                                       v
Timer Bar -> focus description -> GET /projects/:id/jira_tasks (JSON, sorted server-side)
                                       |
                                       v
                              Fuzzy dropdown -> user selects -> task_id + description filled
```
