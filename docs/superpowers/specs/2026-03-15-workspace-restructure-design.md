# Workspace Restructure: Project Membership & Per-Person Rates

## Overview

Restructure the Gold time-tracking app to move currency and hourly rates from the workspace level to the project level. Introduce project memberships that control which users can see and log time to a project, with per-person hourly rates and rate change history. Remove the workspace settings page entirely.

## Goals

1. Remove workspace settings page — hardcode week start (Monday) and time format (24h)
2. Move currency from workspace to individual projects
3. Replace workspace/project/task-level hourly rates with per-person rates on project memberships
4. Control project visibility — employees see only assigned projects
5. Track rate change history for audit and display
6. Make project required on all time entries
7. Remove billable concept — all time is billable

## Data Model

### New Tables

#### `project_memberships`

| Column | Type | Constraints |
|--------|------|-------------|
| id | bigint | PK |
| project_id | bigint | FK projects, not null |
| user_id | bigint | FK users, not null |
| hourly_rate_cents | integer | not null, default 0 |
| created_at | datetime | |
| updated_at | datetime | |

- Unique index on `(project_id, user_id)`
- Index on `user_id`
- `dependent: :destroy` when project is deleted (cascades to rate_changes)
- When a workspace membership is destroyed, all project_memberships for that user in the workspace's projects are also destroyed

#### `rate_changes`

| Column | Type | Constraints |
|--------|------|-------------|
| id | bigint | PK |
| project_membership_id | bigint | FK project_memberships, not null |
| hourly_rate_cents | integer | not null |
| previous_rate_cents | integer | nullable (null for initial rate) |
| changed_by_id | bigint | FK users, nullable |
| changed_at | datetime | not null |
| created_at | datetime | |
| updated_at | datetime | |

- Index on `project_membership_id`
- `dependent: :destroy` when project_membership is deleted
- `changed_at` is the timestamp when the admin made the change (same as `created_at` in practice). The "to" date in the rate history display is derived from the next rate_change record's `changed_at`, not stored.

### Modified Tables

#### `projects` — add column

- `currency` (string, limit 3, default "USD", not null)

#### `projects` — remove columns

- `hourly_rate_cents`
- `billable`

#### `tasks` — remove columns

- `hourly_rate_cents`
- `billable`

#### `workspaces` — remove columns

- `default_currency`
- `default_hourly_rate_cents`
- `week_start`
- `time_format`

#### `users` — remove column

- `default_hourly_rate_cents`

#### `time_entries` — changes

- `project_id` becomes required (not null, `belongs_to :project` without `optional: true`)
- `billable` column removed — all time entries are billable

### Rate Hierarchy (Simplified)

```
time_entry.hourly_rate_cents → project_membership.hourly_rate_cents → 0
```

When a time entry is stopped, the rate is looked up from the user's project membership and locked into `time_entry.hourly_rate_cents`. Once set, it never changes — future rate updates on the membership do not affect past entries.

## Permissions & Navigation

### Sidebar Visibility

| Section | Admin/Owner | Employee |
|---------|------------|----------|
| Time Entries | Yes | Yes |
| Timesheet | Yes | Yes |
| Tags | Yes | Yes |
| Projects (Manage) | Yes | No |
| Clients (Manage) | Yes | No |
| Team (Manage) | Yes | No |
| Reports (Summary, Detailed, Weekly) | Yes | No |

Tags is shown outside the "Manage" group so it remains visible to employees even when "Manage" is hidden.

### Project Access

- **Employees**: see only assigned projects in the time entry project dropdown. No access to project list, settings, members, budget, or rates.
- **Admins/Owners**: see all projects regardless of membership. Full access to project settings, members, and rates.

### Authorization (Controller-Level)

The following controllers require `before_action :require_admin!`:
- `ProjectsController`
- `ClientsController`
- `WorkspaceMembersController` (already has this)
- `SummariesController`
- `DetailedsController`
- `WeekliesController`

This is a security requirement — hiding sidebar links alone is not sufficient.

### Team Page

- Admin-only access.
- Shows all workspace members with their roles.
- Expandable rows showing project assignments with rates per project.
- Admins can assign/unassign users to projects and set rates from here.

## Member Removal Behavior

When an admin removes a user from a project (destroys the `project_membership`):
- The `project_membership` and its `rate_changes` are hard-deleted
- The user's existing time entries on that project are **preserved** — they keep their locked-in `hourly_rate_cents` and remain visible
- The user can still **see** their historical time entries on that project in their time entries list
- The user **cannot** create new time entries or modify existing ones on that project
- The project no longer appears in the user's project dropdown
- If the user is re-added to the project later, a new `project_membership` is created (rate history starts fresh)

## UI Changes

### Removed

- Workspace Settings page (`WorkspaceSettingsController` + views)
- "Workspace" link in sidebar SETTINGS section
- Hourly rate field from user profile page
- Hourly rate field from project form (rates are per-member now)
- Billable checkbox from project form
- Billable checkbox from task form
- Billable column from time entries (all entries are billable)

### Project Page — Tabs

Project edit/show page gets two tabs (admin-only):

**Settings tab:**
- Project Name
- Client (dropdown)
- Currency (dropdown: USD, EUR, GBP, CAD, AUD, JPY, CHF, PLN)
- Color (picker)
- Budget Type + Budget Amount/Hours

**Members tab:**
- List of assigned members with avatar, name, email
- Editable hourly rate input per member (displayed in project's currency)
- "History" link per member — expands inline to show rate change log (date range + rate)
- "Remove" link per member
- "Add Member" button — dropdown/modal to select from workspace members not yet assigned

### Team Page — Expandable Project Assignments

- Each workspace member row shows: avatar, name, email, workspace role, project count
- Expand arrow reveals: list of assigned projects with color dot, name, and rate (in each project's currency)
- "Assign to project" link at bottom of expanded section
- Existing "Add Member" button for adding new workspace members

### Time Entry — Project Dropdown

- Employee: filtered to only projects where user has a `project_membership`
- Admin/Owner: all workspace projects (unchanged)
- Project is required — cannot save a time entry without selecting a project

## Migration Strategy

### Data Migration

1. Copy `workspace.default_currency` to `projects.currency` for all existing projects in each workspace
2. Create a `project_membership` for every existing user × project combination in the workspace (so no one loses access)
3. Set `hourly_rate_cents = 0` on all migrated memberships (no initial `rate_change` records for migrated data)
4. Existing `time_entry.hourly_rate_cents` values are preserved untouched
5. Any time entries without a project: the migration should check for orphans and fail if any exist (expected: none). If found, they must be assigned to a project manually before re-running.
6. Set `time_entries.billable = true` for all existing entries before removing the column

### Column Removal

After migration, remove:
- `workspaces.default_currency`
- `workspaces.default_hourly_rate_cents`
- `workspaces.week_start`
- `workspaces.time_format`
- `projects.hourly_rate_cents`
- `projects.billable`
- `tasks.hourly_rate_cents`
- `tasks.billable`
- `users.default_hourly_rate_cents`
- `time_entries.billable`

### Code Cleanup

- Delete `WorkspaceSettingsController` and views
- Remove workspace settings route
- Remove "Workspace" from sidebar
- Update `WorkspacesController` — remove `default_currency`, `week_start`, `time_format` from permitted params
- Rewrite `TimeEntry#effective_rate_cents` to look up `project_membership.hourly_rate_cents` instead of chaining through task/project/workspace rates
- Update `TimeEntry#set_hourly_rate` to use the rewritten `effective_rate_cents`
- Remove `TimeEntry#inherit_billable_from_project` callback
- Remove `TimeEntry#billable_amount_cents` and `TimeEntry#billable_amount` billable guard (all entries are billable, just return the amount)
- Remove `TimeEntry.scope :billable` and update all call sites (`DashboardController`, report controllers)
- Remove `Project#effective_hourly_rate_cents` method
- Remove `Task#effective_hourly_rate_cents` method
- Update `Project#budget_used_cents` — remove `.where(billable: true)` filter
- Remove `TimeEntriesController#bulk_update` `toggle_billable` action
- Update `TimersController#start` — remove billable logic
- Update `TimesheetsController#update_cell` — remove billable logic
- Hardcode week start to Monday (1) in `DashboardController#start_day` and anywhere else referenced
- Update sidebar partial: show Tags outside the Manage group; hide Manage and Reports sections for non-admin users
- Update project dropdown query in time entry form to filter by membership for employees
- Add `before_action :require_admin!` to `ProjectsController`, `ClientsController`, `Reports::SummariesController`, `Reports::DetailedsController`, `Reports::WeekliesController`
- Add project membership validation in `TimesheetsController#update_cell` for employees
- Update `TimeEntry` model: make `project` required (`belongs_to :project` without `optional: true`)
- Note: workspace membership destroy cascading to project memberships requires a `before_destroy` callback on `WorkspaceMembership` (not a DB FK — there is no direct FK relationship)

## Rate History Behavior

- When an admin changes a member's rate on a project, a `rate_change` record is created with the new rate, previous rate, who changed it, and when
- The initial rate set when a member is first added also creates a `rate_change` record (with `previous_rate_cents: null`)
- Rate history is displayed inline on the Project > Members tab, expandable per member
- History shows: rate amount (in project currency), date range (from → to or "Current"). The "to" date is derived from the next `rate_change` record's `changed_at`.
- Sorted newest first

## Budget Calculation

Money budgets (`Project#budget_used_cents`) continue to use `time_entry.hourly_rate_cents` (locked-in rates). The `.where(billable: true)` filter must be removed since all entries are now billable. Otherwise the per-entry rate is already the source of truth for billing calculations.
