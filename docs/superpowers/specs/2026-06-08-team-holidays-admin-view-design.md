# Admin "Team Holidays" View — Design

**Date:** 2026-06-08
**Status:** Approved, ready for implementation plan

## Problem

Admins/owners cannot see who took holidays across the team. The Holidays page
(`/holiday_requests`) shows only the current user's own requests ("My Requests")
plus an "upcoming team time off" list limited to teammates on shared projects.
There is no view of all members' holidays.

The controller already loads the needed data — `@all_requests` (every holiday
request in the workspace, with `:user` and `:reviewed_by`, assigned only for
admins/owners) — but the view never renders it.

## Goal

Add an admin-only **Team Holidays** section to the existing Holidays page that
lists **every member's** requests across **all statuses** (approved, pending,
cancelled), sorted by holiday start date, newest first. Past and future.

## Scope

- View change to `app/views/holiday_requests/index.html.erb` (new section).
- One-line controller reorder (`@all_requests` by `start_date: :desc`).
- No new route, no nav change, no schema change.
- Admin/owner only (employees must not see the section).

## Existing infrastructure (reused)

- `HolidayRequestsController#index` assigns, for admins/owners:
  `@all_requests = current_workspace.holiday_requests.includes(:user, :reviewed_by).order(created_at: :desc)`.
  This variable is currently unused by any view, so changing its order is safe.
- `HolidayRequest`: `enum status { pending: 0, approved: 1, cancelled: 2 }`;
  `business_days` integer; `start_date`/`end_date`; `belongs_to :user`.
- View helper `holiday_status_style(status)` (already used by "My Requests").
- Existing row markup patterns: avatar + name (Team Time Off section), and the
  status pill (My Requests section) — both reused.

## Controller change

In `HolidayRequestsController#index`, change the admin `@all_requests` ordering
from `created_at: :desc` to `start_date: :desc` so the section reads
chronologically by holiday date:

```ruby
@all_requests = current_workspace.holiday_requests
  .includes(:user, :reviewed_by)
  .order(start_date: :desc)
```

## View change

In `app/views/holiday_requests/index.html.erb`, add a new section (placed after
the existing "Team Time Off" upcoming block), rendered only when admin/owner and
there is data:

```erb
<% if current_user.admin_or_owner?(current_workspace) && @all_requests&.any? %>
  <div class="space-y-2">
    <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">Team Holidays</h2>
    <div class="m3-card-outlined overflow-hidden">
      <% @all_requests.each do |request| %>
        <div class="flex items-center gap-3 p-4 border-b" style="border-color: var(--color-outline-variant)">
          <div class="m3-avatar m3-avatar-sm"><%= request.user.name.first(2).upcase %></div>
          <div class="flex-1">
            <div class="text-sm font-medium" style="color: var(--color-on-surface)"><%= request.user.name %></div>
            <div class="text-xs" style="color: var(--color-outline)">
              <%= request.start_date.strftime("%b %-d") %> &ndash; <%= request.end_date.strftime("%b %-d, %Y") %>
              &middot; <%= request.business_days %> days
            </div>
          </div>
          <span class="text-[10px] font-semibold uppercase tracking-wider px-2.5 py-1 rounded-full"
                style="<%= holiday_status_style(request.status) %>">
            <%= request.status %>
          </span>
        </div>
      <% end %>
    </div>
  </div>
<% end %>
```

The section is hidden entirely when there are no requests (no empty-state card).

## Testing (Minitest)

`test/controllers/holiday_requests_controller_test.rb` (new or appended):

- **Admin sees team holidays:** as an admin/owner, after another user has a
  holiday request, GET index renders that other user's name within the page and
  the "Team Holidays" heading is present.
- **Employee does not:** as an employee, GET index does NOT contain the "Team
  Holidays" heading (and not another user's request via this section).
- **All statuses shown:** a cancelled request from another user still appears in
  the admin view (status pill text "cancelled").
- **Ordering:** `@all_requests` returned in `start_date: :desc` order — assert
  via two requests with different start dates (most recent first in body).
- **Edge:** with no workspace requests, the "Team Holidays" heading is absent
  for an admin (section hidden).

## Out of scope

- Filtering by year/date range (kept simple per decision).
- A separate page or nav entry.
- Changes to balances, approvals, or the upcoming "Team Time Off" block.
