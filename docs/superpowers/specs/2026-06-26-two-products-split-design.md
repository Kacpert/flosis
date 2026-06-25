# Split into Two Products: Time & HR / Workshop

**Date:** 2026-06-26
**Status:** Approved, implementing

## Summary

Split the single app into two products that share one DB, models, and Jira sync.
The split is a **UI/access partition** over the same data, selected by a per-user
"current product" mode (mirrors the workspace switcher).

- **Time & HR** — Time Entries, Timesheet, Holidays, Feedback, Tags, Projects,
  Clients, Team, Reports (Summary/Detailed/Weekly/Project Report).
- **Workshop** — Jira Tasks, Workshop (Idea→Brief / Brief→Task).

Global (outside the switcher): Profile, Workspace Settings, theme, Sign Out.

## Decisions (locked)

- Same app, one DB, shared models. No data split.
- Product switcher at the **top of the sidebar**; remembers last-used product per
  user (in session). Renders as a static label when the user can access only one.
- **Per-user access** on `WorkspaceMembership`: `time_hr_access`, `workshop_access`
  (booleans). Named `_access` to avoid confusion with the existing workspace-level
  `workspaces.workshop_enabled` *feature* flag.
- Workshop visible only when BOTH the workspace feature (`workspaces.workshop_enabled`)
  AND the membership grant (`workshop_access`) are true. Time & HR visible when
  `time_hr_access`.
- **Backfill on migration:** admins/owners → both access true; employees →
  `time_hr_access` true, `workshop_access` false; clients → unchanged (role rules
  already restrict them to Jira Tasks).
- Jira Tasks belongs to the **Workshop** product.
- Default landing: Time & HR → Time Entries (current root); Workshop → `/workshop`.
  `/` redirects to the current product's landing.
- User-facing names: **"Time & HR"** and **"Workshop"**.

## Data model

`WorkspaceMembership` gains:
- `time_hr_access` (boolean, default true)
- `workshop_access` (boolean, default false)

Migration backfills existing rows by role (see above).

`User` helpers:
- `can_access_time_hr?(workspace)` → membership.time_hr_access (clients: false).
- `can_access_workshop?(workspace)` → workspace.workshop_enabled? &&
  membership.workshop_access (clients: true, since they're Jira-Tasks-only and
  that lives in Workshop).
- `accessible_products(workspace)` → ordered list of `:time_hr` / `:workshop`.
- `default_product(workspace)` → first accessible (`:time_hr` preferred, else
  `:workshop`).

## Current product

New `WorkspaceScoped` helper `current_product`:
- Read `session[:product]` (symbol/string `"time_hr"` | `"workshop"`).
- Validate the user still has access; else fall back to `default_product`.
- Persist the resolved value back to `session[:product]`.
- `helper_method :current_product` for the layout.

Switching: `POST /product/switch` with `product` param → validates access, sets
`session[:product]`, redirects to that product's landing.

## Routing & enforcement

- `root` redirects to the current product's landing (`time_entries` or `workshop`).
- `POST /product/switch` → `ProductsController#switch`.
- Enforcement helper in `Authorization`:
  - `require_product!(name)` as a `before_action`; redirects to the current
    product landing with an alert when the user lacks access.
- Apply `require_product!(:workshop)` to: `WorkshopController`,
  `BriefChatSessionsController`, `BriefCommitsController`, `JiraTasksController`,
  `ChatSessionsController`, `BreakdownChatSessionsController`,
  `TaskBreakdownsController`, `JiraController` (jira_tasks/sync actions used by the
  Jira board).
- Apply `require_product!(:time_hr)` to: `TimeEntriesController`,
  `TimesheetController`, `TimerController`, `HolidayRequestsController`,
  `HolidayBalanceEntriesController`, `FeedbackMeetingsController`, `TagsController`,
  `ProjectsController`, `ProjectMembershipsController`, `ClientsController`,
  `WorkspaceMembersController`, `Reports::*`.
- **Clients unchanged:** `redirect_clients_to_jira` still restricts client-role
  users to Jira Tasks; their product resolves to `:workshop`.
- Guards must not fight each other: `require_product!` runs AFTER
  `set_current_workspace`/`redirect_clients_to_jira` and only redirects when the
  request is for a product the user can't access. The product landing it redirects
  to is always one the user CAN access (default_product), so no loop.

## Sidebar

`application.html.erb` nav splits into two partials/sections; only the
`current_product` set renders. A product switcher renders at the top (above the
nav) listing accessible products. Global user menu (Profile / Workspace Settings /
Sign Out / theme) stays at the bottom, unchanged.

- Time & HR nav: Time Entries, Timesheet, Holidays, Feedback, Tags, (admin:)
  Projects, Clients [if clients_enabled], Team, Reports group.
- Workshop nav: Jira Tasks, (admin + workshop:) Workshop.

## Team page

The Team (`workspace_members`) edit UI gains two checkboxes per member —
**Time & HR access** and **Workshop access** — permitted in the members
controller and shown only to admins. Editing a member updates their membership
flags.

## Error handling

- Switching to a product the user can't access → redirect to their default product
  with an alert; never set an inaccessible product in session.
- Direct-URL access to a forbidden product → `require_product!` redirects with an
  alert (no 500, no leak).
- A user who loses access to their current product mid-session (admin revokes) →
  `current_product` falls back to default on the next request.

## Testing (Minitest)

- `User` access helpers: matrix of role × workspace flag × membership flag.
- `current_product` resolution: session honored when accessible; falls back when
  not; persists.
- `ProductsController#switch`: sets session + redirects; rejects inaccessible.
- `require_product!`: blocks forbidden controller access (Workshop controller for a
  Time&HR-only user; a Time&HR controller for a Workshop-only user) and allows
  permitted.
- Sidebar: shows only current product's items; switcher lists accessible products;
  single-access user sees a static label.
- Clients: still restricted to Jira Tasks; resolve to Workshop product.
- Migration backfill: admin both, employee time_hr only.

## Out of scope

- Separate billing/pricing per product.
- Two deployed apps / separate databases.
- Changing what any existing feature does — only WHERE it appears and WHO can reach it.
