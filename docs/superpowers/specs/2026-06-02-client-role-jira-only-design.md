# Client Role — Jira-Tasks-Only Access

## Summary

Finish wiring the existing `client` workspace role so an external client can log
in and see **only Jira Tasks** (for the projects they're assigned to), with full
use of the task AI features (chat, estimate & breakdown, refine). Everything else
— Time Entries, Timesheet, Projects, Clients, Team, Holidays, Feedback, Tags,
Reports — stays hidden and inaccessible. Reports for clients are explicitly out of
scope for now.

The `client` role already exists (`WorkspaceMembership` enum `client: 3`, helpers
`User#client_role?`, the Team member forms offer "Client", and the nav already
hides non-client sections from clients). What's missing is real access: a client
currently can't reach Jira Tasks (every relevant controller uses
`require_employee!`, which excludes clients), the Jira nav link is hidden from
clients, and the landing page (`root` → `time_entries#index`) requires an
employee, so a client would hit a dead end. This spec completes that wiring.

**A "client account" is a login (a `User` with workspace role `client`).** It is
unrelated to the `Client` model (the company/contact record like "Jesper Elvium").
We do not link the two models here.

**Deployment context:** Single-user-operated SaaS deployed via Capistrano to
clar.rubyonsaas.com. No new infrastructure.

## Goals & Non-Goals

**Goals**
- A `client` user logs in and lands on Jira Tasks.
- The client sees Jira Tasks only for projects they're a member of.
- The client has full task AI access (chat, breakdown, refine) like an employee.
- The client's nav shows only Jira Tasks plus the user section (profile, theme,
  sign out).
- Access is enforced in the controllers (and data scoped to the client's
  projects), not merely hidden in the nav.

**Non-Goals (YAGNI)**
- No Reports for clients (later).
- No link between the `client` login role and the `Client` (company) model.
- No new "Add client" screen — reuse the Team panel (role "Client").
- No client write-back to Jira (unchanged from current behavior).

## Authorization

### New guard — `require_client_or_employee!`
Add to the `Authorization` concern alongside `require_employee!`:
- Allows `client`, `employee`, `admin`, `owner`.
- Redirects everyone else (no membership) to `root_path` with an alert.

Backed by a new `User#client_or_employee?(workspace)` (true for client + the
existing `at_least_employee?` roles).

### Where the guard is applied (Jira/AI only)
Replace `require_employee!` with `require_client_or_employee!` in exactly these
controllers/actions:
- `JiraTasksController` — `index`, `show`, `board_data` (NOT `refresh`; sync stays
  admin-only).
- `TaskBreakdownsController` — all actions.
- `ChatSessionsController` — all actions.
- `BreakdownChatSessionsController` — all actions.
- `TaskDraftsController` — `index`.
- `JiraController#jira_tasks`.

Everything else keeps `require_employee!` / `require_admin!`, so a client visiting
those is redirected.

### Data scoping (defense in depth)
The nav hiding is cosmetic; access is enforced server-side in three layers:

1. **Controller guard** lets clients reach only Jira/AI endpoints.
2. **Project scoping.** A client sees Jira tasks only for projects they belong to.
   Reuse the existing membership-scoped project list (the non-admin branch of
   `WorkspaceScoped#available_projects`), narrowed to `external_type: "jira"`. Add
   a helper that returns "jira projects visible to the current user":
   - admin/owner → all workspace Jira projects,
   - everyone else (employee, client) → Jira projects they have a
     `ProjectMembership` for.
   `JiraTasksController#index` and `#board_data` build their project/board/sprint
   lists from this helper.
3. **Per-record check.** `JiraTasksController#show` and `#board_data` must verify
   the requested task/board belongs to a visible project; otherwise redirect to
   `jira_tasks_path` with an alert. This stops a client from reaching another
   project's task by guessing an ID. Same check applies transitively to the AI
   controllers via their `set_task`: for non-admins (employee and client),
   `set_task` is scoped to visible (membership) projects, so a `find` on an
   out-of-scope task raises `RecordNotFound` → handled as a redirect to
   `jira_tasks_path`. Admin/owner keep the unscoped lookup.

### Client landing & redirect containment
`root` is `time_entries#index` (employee-only). Add a `before_action` in
`ApplicationController`, running before the per-controller role guards, that:
- if the current user is a `client` in the current workspace, AND
- the request path is not under a client-allowed prefix, then
- redirect to `jira_tasks_path`.

Client-allowed prefixes: `/jira_tasks` (which covers the nested
breakdown / chat_session / task_drafts routes), `/profile`, and the session
routes (`/session`, sign out). Workspace switch/create is NOT allowed for
clients. The hook never redirects a request already under an allowed prefix, so
there is no loop.

This single hook covers both the post-login landing (client hitting `root`) and
any direct-URL attempt, and is written to avoid redirect loops (it never
redirects a request that is already under an allowed prefix). Non-clients are
unaffected.

## Navigation

Edit `app/views/layouts/application.html.erb`:

- **Jira Tasks link**: move it out of the `unless client_role?` block so clients
  see it. Keep the existing guard that the workspace has at least one Jira
  project.
- **Time Entries / Timesheet** (`unless client_role?`): unchanged — hidden from
  clients.
- **Manage (Projects, Clients, Team)** and **Reports** (`admin_or_owner?`):
  unchanged — invisible to clients.
- **Holidays, Feedback, Tags** (`unless client_role?`): unchanged — hidden.
- **User section (bottom):** Profile, Theme, Sign Out remain for clients. Wrap
  **"Switch Workspace"** and **"New Workspace"** in `unless client_role?` — an
  external client shouldn't hop between or create workspaces.

Net result for a client: nav shows only **Jira Tasks** plus profile / theme /
sign out. The top bar already shows the workspace name (not the timer bar) for
non-employees, which is correct.

## Account creation

No new UI. Admins use the existing **Team → add member → role "Client"** flow
(the form already offers "Client"), then assign the client to the relevant
project via the existing project-membership UI. The invitation email already
works (`InvitationMailer`).

For verification, create one real test client account (via `rails console` /
seed on production): a `User` with `client` role in the target workspace,
assigned to a Jira project (the one containing DEV-807). Its credentials are
reported back so the flow can be Playwright-verified.

## Error Handling

- Client hitting a non-allowed page → redirected to `jira_tasks_path` (via the
  ApplicationController hook) or to `root_path` with an alert (per-controller
  guard for employee/admin-only controllers, which then bounces to Jira).
- Client requesting a task/board outside their projects → redirect to
  `jira_tasks_path` with "You don't have access to that." 
- No Jira projects assigned to the client → Jira Tasks index renders its normal
  empty state (no projects), not an error.

## Testing (Minitest)

- **Authorization / User:** `client_or_employee?` true for client + employee +
  admin + owner, false for no-membership; `require_client_or_employee!` allows a
  client, blocks a non-member.
- **JiraTasksController:** a client sees only tasks from assigned projects; a
  client is redirected when opening a task outside their projects; a client
  cannot call `refresh` (admin-only).
- **AI controllers:** a client with project access can create/show a chat and a
  breakdown; a client without access to that task's project is blocked.
- **Employee/admin/owner pages:** a client is redirected from
  `time_entries#index`, `projects#index`, and `reports/*`.
- **Landing:** a client requesting `root` is redirected to `jira_tasks_path`; a
  non-client is not.

## Open Questions

None — all resolved during brainstorming.
