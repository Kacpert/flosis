# Calculated Cost in the Detailed Report — Design

**Date:** 2026-06-08
**Status:** Approved, ready for implementation plan

## Problem

Admins want to see labour **cost** (total and per user) in the Detailed report,
derived from per-project member hourly rates. Cost must be admin-only and must
**not** appear in the PDF export — only in the on-screen (HTML) report.

## Existing infrastructure (already built — do not rebuild)

- **Per-project, per-member rates:** `project_memberships.hourly_rate_cents`,
  edited on the Project → Members tab (`ProjectMembershipsController`, admin-only),
  with rate history in `rate_changes`.
- **Per-entry cost:** `TimeEntry#billable_amount_cents` =
  `(duration_seconds / 3600.0 * effective_rate_cents).round`, where
  `effective_rate_cents` uses the entry's snapshotted `hourly_rate_cents` (set at
  stop time) and falls back to the member's project rate.
- **Money permission:** `can_see_money?(workspace)` = `admin_or_owner?` (helper
  method available in controllers/views).
- **Per-project currency:** `projects.currency` (3-letter string, default "USD").

The only gap is **displaying cost in the Detailed report**. This design reads
existing data; it changes no rate model or schema.

## Scope

- **Detailed report HTML only** (`/reports/detailed`, `Reports::DetailedsController#show`
  + `app/views/reports/detaileds/show.html.erb`).
- **Admin-only** (controller already has `before_action :require_admin!`; cost UI
  additionally wrapped in `can_see_money?` for defence in depth).
- **No PDF, no CSV.** `export_pdf` and `export_csv` are separate methods and
  builders — cost is simply not added to them.

## Data (controller `#show`)

Reuse the already-loaded `@entries` (array, includes :project/:user). Compute
in-memory (no extra queries — `billable_amount_cents` is a Ruby method):

- `@total_cents = @entries.sum(&:billable_amount_cents)`
- Per-user cost is computed in the view from each user's entries
  (`entries.sum(&:billable_amount_cents)`), mirroring how `user_total` (seconds)
  is already computed inline in the view.

**Currency display:**
- When a single project is selected (`@project` present): use `@project.currency`.
- Across mixed projects (no project filter): show the summed amount with **no**
  currency symbol (neutral number). No FX conversion.

A view helper formats money:

```ruby
# returns e.g. "1,234.50 USD" (currency given) or "1,234.50" (nil)
def format_money(cents, currency = nil)
  amount = ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", cents.to_i / 100.0))
  currency.present? ? "#{amount} #{currency}" : amount
end
```

Add it to `ApplicationHelper` (where `format_duration_hm` already lives, so the
Detailed view reaches it the same way).

## View (`app/views/reports/detaileds/show.html.erb`)

All cost UI wrapped in `<% if can_see_money? %>`:

1. **Summary cards (top):** add a third `.stat-card` **TOTAL COST** next to the
   existing Total Hours / Team Members cards, showing
   `format_money(@total_cents, @project&.currency)`.
2. **Per-user section header:** next to each user's hours and percentage (the
   `user_pct` / `user_total` line in the view), append their cost using
   `format_money(entries.sum(&:billable_amount_cents), @project&.currency)`,
   e.g. `160:00 · 47.9% · 1,234.50 USD`.

## Testing (Minitest)

- **Controller (`test/controllers/reports/detaileds_controller_test.rb`):**
  - `@total_cents` equals the sum of fixture entries' `billable_amount_cents`
    for a known range/project with set rates.
  - admin required (employee → redirect to root) — confirm existing guard.
- **Cost-not-in-PDF:** a test asserting `export_pdf` returns a `application/pdf`
  response and the response body does not contain the cost figure / currency
  string that the HTML shows (guards the "not in PDF" requirement).
- **Edge cases:** zero-rate member → cost 0, no error; empty date range →
  `@total_cents == 0`.

## Out of scope

- Rate-setting UI (already exists on the Project → Members tab).
- Summary and Weekly reports, PDF, CSV exports.
- Currency conversion / a single workspace currency.
