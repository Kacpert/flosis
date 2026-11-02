# Project Report Page — Design

**Date:** 2026-06-19
**Status:** Approved, ready for implementation plan

## Problem

We want a per-project monthly report showing three statistics:
1. Hours worked that month (per-user breakdown + total).
2. How many tasks moved to "Customer Acceptance" in Jira that month.
3. How many bugs were worked on that month.

## Access & entry point

- New **sidebar nav item** under the Reports section: "Project Report".
- Opens `GET /reports/project` (admin/owner only — reuse `require_admin!`).
- The page has a **project dropdown** (defaults to the first active project by name)
  and a **month picker** (defaults to the current month, Warsaw). Both are query
  params (`project_id`, `month` as `YYYY-MM`).

This keeps one clean global entry point even though the report is per-project
(mirrors how the Detailed report uses a project dropdown).

## Statistics (for the selected project + month)

Month range = `month.beginning_of_month..month.end_of_month` (Warsaw zone).

1. **Hours worked** — from completed time entries on the project in range:
   - Total: `project.time_entries.completed.in_range(from, to).sum(:duration_seconds)`.
   - Per-user: grouped by user, each with seconds and % of the project total.
   - Rendered Detailed-report style: a total, then a row per user (hours + %).

2. **Tasks → Customer Acceptance** — Jira tasks now in that column, updated in month:
   `project.tasks.jira_synced.where(jira_status_name: "Customer Acceptance")
     .where(jira_updated_at: from..to).count`.

3. **Bugs worked on** — Bug tasks updated in month:
   `project.tasks.jira_synced.where(issue_type: "Bug")
     .where(jira_updated_at: from..to).count`.

(Real Jira status/type values confirmed in production: status "Customer Acceptance"
and issue_type "Bug" both exist.)

## Supporting data change (enables stats 2 & 3)

Tasks currently store only Rails `created_at`/`updated_at`; `updated_at` bumps on
every sync, so it can't represent "Jira activity this month". Add a real Jira
timestamp:

- **Migration:** add `tasks.jira_updated_at` (datetime, nullable, indexed with
  `project_id` for the report queries).
- **`JiraClient`:** add `"updated"` to the requested `fields` (line ~42) and
  extract `updated: fields["updated"]` in the parsed issue hash (~line 217+).
- **`JiraSyncService`:** when upserting a task, set
  `jira_updated_at: issue[:updated]`.

Accuracy note: stats 2 & 3 reflect each task's Jira "updated" timestamp, which is
populated on sync. After this ships, tasks get their real timestamp on the next
sync (a task last updated in May shows a May timestamp), so once a full sync has
run the month-scoped counts are correct. The page shows a small note: "Jira
stats reflect the latest synced data."

## Components

- **Service `ProjectMonthlyReport`** (`app/services/project_monthly_report.rb`),
  PORO initialized with `project:, month:` (a Date). Exposes:
  - `total_seconds` → Integer
  - `per_user_hours` → array of `{ user:, seconds:, percent: }`, sorted desc by
    seconds
  - `customer_acceptance_count` → Integer
  - `bugs_count` → Integer
  Keeps the controller thin and the stats unit-testable.
- **Controller `Reports::ProjectReportsController#show`** — resolves project
  (from `project_id` or default) + month (from `month` or current), builds the
  service, renders. Admin-only; workspace-scoped (project must belong to the
  current workspace).
- **Route:** `resource :project_report, only: [:show]` under the existing
  `namespace :reports` (yielding `/reports/project` and
  `reports_project_report_path`). Match the existing reports route style.
- **View `app/views/reports/project_reports/show.html.erb`** — project dropdown,
  month picker, three stat cards; hours card has the per-user rows + total.
- **Sidebar:** add the "Project Report" link in the Reports group of
  `app/views/layouts/application.html.erb`, gated on admin/owner (and not shown
  to clients).

## Testing (Minitest)

- **`ProjectMonthlyReport`:**
  - `total_seconds` sums only completed entries in the month for the project;
    excludes other months/projects and running timers.
  - `per_user_hours` groups correctly, percentages sum ~100, sorted desc.
  - `customer_acceptance_count` counts only jira tasks in "Customer Acceptance"
    with `jira_updated_at` in month; excludes other statuses / other months /
    non-jira tasks.
  - `bugs_count` counts only `issue_type == "Bug"` with `jira_updated_at` in
    month; excludes non-bugs / other months.
- **Controller:** admin renders the page with the three figures for a chosen
  project & month; employee blocked (→ root); defaults to current month + first
  project; a project from another workspace is not accessible.
- **Sync/client:** `jira_updated_at` is parsed from the issue and persisted on
  the task (extend existing jira sync/client tests; `"updated"` is in the
  requested fields).
- **Sidebar:** the Project Report link shows for an admin and is absent for a
  client/employee where appropriate.

## Out of scope

- Status-transition history (we use the single Jira `updated` timestamp, not a
  per-status entered-at log).
- CSV/PDF export of this report.
- Date ranges other than a single calendar month.
