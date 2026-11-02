# Clients Feature Toggle (workspace-level) — Design

**Date:** 2026-06-02
**Status:** Approved, ready for implementation plan

## Problem

The **Clients tab** (`/clients` — the separate client-entity list, e.g. "Jesper Elvium")
is not used and clutters the sidebar. We want admins to turn the whole Clients
**feature** on or off per workspace, rather than hard-removing it from the code.

This is about the Clients **feature/tab**, NOT the client **role** (the
Jira-tasks-only login accounts). Those are unrelated and stay as-is.

## Goal

- Admin/owner can toggle the Clients feature for their workspace.
- **Default: OFF.** Existing and new workspaces start with Clients hidden; an
  admin must explicitly enable it.
- When OFF: the Clients nav link is hidden for everyone in the workspace, and
  `/clients` URLs redirect away (access blocked, not just hidden).
- Existing `clients` records are never modified — disabling only hides the
  feature; re-enabling shows the same data again.

## Data

Add a boolean column to `workspaces`:

- `clients_enabled` — `boolean`, `null: false`, `default: false`.
- Migration backfills existing rows to `false` (so the current workspace starts
  disabled, matching the present desired state).

`Workspace#clients_enabled?` is provided by the column. No JSON settings store —
a single typed column is clearer; more flags can be added later if real demand
appears (YAGNI).

## Settings page

New **Workspace Settings** page, admin/owner only.

- Route: `resource :workspace_settings, only: [:show, :update]` → `/workspace_settings`.
- `WorkspaceSettingsController`:
  - `include WorkspaceScoped`
  - `before_action :require_admin!`
  - `show` — renders the settings form.
  - `update` — strong params permit `:clients_enabled`; updates
    `current_workspace`; redirects back to `/workspace_settings` with a notice.
- View `workspace_settings/show.html.erb`: a **Features** section with a labeled
  toggle for "Clients" using the project's existing `m3-*` design system
  (`m3-card-elevated`, `m3-checkbox`, `m3-btn m3-btn-filled` — no raw inline
  styles; DaisyUI is not wired into the Tailwind build, so we stay within the
  established system), submitted via a standard form. Scaled for future flags.

## Entry point

Add a **"Workspace Settings"** link to the user-menu dropdown
(`application.html.erb`), shown only when
`current_user.admin_or_owner?(current_workspace)`. The menu currently holds
Profile + Sign Out; the new link sits with Profile (above the Sign Out divider).
Keeps the sidebar uncluttered.

## Enforcement (off behavior)

1. **Nav link** (`application.html.erb`): re-add the Clients sidebar link,
   wrapped so it renders only when `current_workspace.clients_enabled?` AND the
   user is admin/owner (existing gate). Hidden otherwise.
2. **Access guard** (`ClientsController`): `before_action` redirecting to
   `root_path` with an alert when `!current_workspace.clients_enabled?`. Typing
   `/clients` while disabled bounces the user out. Runs alongside the existing
   `require_admin!`.

## Testing (Minitest)

- **Model/migration:** new workspaces default `clients_enabled` to `false`.
- **WorkspaceSettingsController:**
  - employee is blocked (`require_admin!`);
  - admin `update` flips `clients_enabled` true→false and false→true;
  - `show` renders for admin.
- **ClientsController:** redirects to root when feature disabled; renders index
  when enabled (admin).
- **Nav:** Clients link present when enabled + admin; absent when disabled;
  absent for non-admins regardless.
- Fixtures: ensure a workspace with `clients_enabled: true` exists for the
  enabled-path tests (existing client/clients tests may assume the feature is
  on — update those fixtures/setups so they don't break under the new default).

## Out of scope

- The client **role** (Jira-tasks-only accounts) — untouched.
- Any change to client data, archiving, or the clients schema.
- A generic feature-flag framework — single column for now.
