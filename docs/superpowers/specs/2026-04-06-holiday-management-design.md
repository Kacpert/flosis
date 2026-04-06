# Holiday Management System — Design Spec

## Overview

A holiday/time-off management system for Gold. Employees get 20 days per year (granted by admin initially, then automatically on January 1st). Unused days carry over indefinitely with no cap. Balance is tracked via a ledger of entries, providing full audit history.

## Requirements Summary

- Employees start with 0 days; admin grants initial balance manually with a note
- 20 days auto-granted each January 1st for all active members
- Unused days roll over to the next year, no cap
- Single leave type (full days only) with a note
- Requests cover date ranges (multiple consecutive days)
- Any workspace admin can approve or cancel requests
- Email notification on approval/cancellation
- Employees see their own balance, requests, and approved time off for project colleagues
- Admins can adjust balance manually with a required note
- Full ledger history visible to employees and admins

## Data Model

### `holiday_requests`

| Column | Type | Notes |
|---|---|---|
| id | bigint PK | auto |
| user_id | bigint FK | references users |
| workspace_id | bigint FK | references workspaces |
| start_date | date | not null |
| end_date | date | not null |
| business_days | integer | not null, computed weekdays in range |
| note | text | optional, employee's note |
| status | integer | not null, default 0. enum: pending (0), approved (1), cancelled (2) |
| reviewed_by_id | bigint FK nullable | references users (the admin) |
| reviewed_at | datetime nullable | when reviewed |
| created_at | datetime | |
| updated_at | datetime | |

**Indexes:**
- `[workspace_id, user_id]`
- `[workspace_id, status]`
- `[user_id, start_date, end_date]` (overlap validation)

### `holiday_balance_entries`

| Column | Type | Notes |
|---|---|---|
| id | bigint PK | auto |
| user_id | bigint FK | references users |
| workspace_id | bigint FK | references workspaces |
| entry_type | integer | not null. enum: yearly_grant (0), admin_adjustment (1), deduction (2), reversal (3) |
| days | integer | not null, positive = add, negative = deduct |
| note | text | required for admin_adjustment, auto-generated for others |
| holiday_request_id | bigint FK nullable | links deductions/reversals to request |
| created_by_id | bigint FK nullable | admin user or null for system |
| created_at | datetime | |
| updated_at | datetime | |

**Indexes:**
- `[workspace_id, user_id]`
- `[user_id, entry_type]` (for idempotent yearly grant check)

### Balance Calculation

```ruby
HolidayBalanceEntry.where(user_id:, workspace_id:).sum(:days)
```

## Models

### HolidayRequest

**Associations:**
- `belongs_to :user`
- `belongs_to :workspace`
- `belongs_to :reviewed_by, class_name: "User", optional: true`
- `has_many :holiday_balance_entries`

**Validations:**
- `start_date` and `end_date` present
- `start_date <= end_date`
- `start_date` not in the past (on create)
- No overlapping pending/approved requests for the same user (custom validation)
- Sufficient balance: `user.holiday_balance(workspace) >= business_days` (on create)

**Callbacks:**
- `before_validation`: compute `business_days` from weekdays between start_date and end_date

**Scopes:**
- `pending`, `approved`, `cancelled`

**Methods:**
- `approve!(admin)` — wraps in transaction: sets status to approved, reviewed_by, reviewed_at. Creates `HolidayBalanceEntry` with `entry_type: :deduction, days: -business_days`. Delivers `HolidayRequestMailer#approved`.
- `cancel!(admin)` — wraps in transaction: sets status to cancelled, reviewed_by, reviewed_at. If previously approved, creates `HolidayBalanceEntry` with `entry_type: :reversal, days: +business_days`. Delivers `HolidayRequestMailer#cancelled`.

### HolidayBalanceEntry

**Associations:**
- `belongs_to :user`
- `belongs_to :workspace`
- `belongs_to :holiday_request, optional: true`
- `belongs_to :created_by, class_name: "User", optional: true`

**Validations:**
- `days` present and non-zero
- `note` present when `entry_type` is `admin_adjustment`

**Enum:**
- `entry_type`: yearly_grant (0), admin_adjustment (1), deduction (2), reversal (3)

### User (concern: Holidayable)

- `has_many :holiday_requests`
- `has_many :holiday_balance_entries`
- `holiday_balance(workspace)` — `holiday_balance_entries.where(workspace:).sum(:days)`

## Controllers

### HolidayRequestsController

**Authorization:**
- `require_employee!` for index, new, create
- `require_admin!` for approve, cancel

**Actions:**

- **index** — Employee view: own requests + approved requests from colleagues on shared projects. Admin view: all requests with pending tab for action. Shows current balance prominently.
- **new** — Form with start_date, end_date, note. Shows current balance.
- **create** — Creates pending request. Validates balance sufficiency.
- **approve** (PATCH) — Admin approves. Creates deduction entry. Sends email.
- **cancel** (PATCH) — Admin cancels. Creates reversal if was approved. Sends email.

### HolidayBalanceEntriesController

**Authorization:**
- `require_admin!` for new, create
- index: employees see own, admins see any user's

**Actions:**

- **index** — Full ledger for a user. Filterable by year. Shows running balance.
- **new** — Admin form: days (+/-), note (required).
- **create** — Creates admin_adjustment entry.

## Routes

```ruby
# Inside workspace scope
resources :holiday_requests, only: [:index, :new, :create] do
  member do
    patch :approve
    patch :cancel
  end
end

resources :holiday_balance_entries, only: [:index, :new, :create]
```

## Views

### Employee Views

1. **Holiday dashboard** (`holiday_requests#index`):
   - Current balance displayed prominently at top
   - "Request Time Off" button
   - List of own requests: date range, business days count, status badge (pending/approved/cancelled), note
   - Section: "Upcoming time off on your projects" — approved requests from project colleagues

2. **New request form** (`holiday_requests#new`):
   - Start date and end date fields
   - Computed business days shown dynamically (Stimulus controller)
   - Note textarea
   - Current balance displayed
   - Submit button

3. **Balance history** (`holiday_balance_entries#index`):
   - Chronological ledger: date, entry type, days (+/-), note, who made the change
   - Year filter
   - Running balance column

### Admin Views

1. **Pending requests** (tab on `holiday_requests#index`):
   - All pending requests: employee name, dates, business days, note, employee's current balance
   - Approve / Cancel buttons per request

2. **Balance management** (`holiday_balance_entries#index` for a specific user):
   - Full ledger for the employee
   - "Adjust Balance" button -> form (days +/-, note required)

3. **Employee overview** (separate tab or section on the admin holiday_requests#index):
   - List of all employees with their current balance
   - Link to view ledger / adjust balance for each

## Email Notifications

### HolidayRequestMailer

- **`approved(holiday_request)`** — "Your time off request for [start_date] - [end_date] ([business_days] days) has been approved by [admin_name]."
- **`cancelled(holiday_request)`** — "Your time off request for [start_date] - [end_date] has been cancelled by [admin_name]."

Uses Action Mailer, delivered via Solid Queue (deliver_later).

## Cron Job: Yearly Grant

**`HolidayYearlyGrantJob`**

- Scheduled via Solid Queue recurring schedule for January 1st
- Iterates all active WorkspaceMemberships with roles: employee, admin, owner (not client)
- For each, creates a `yearly_grant` balance entry: `days: 20, note: "Annual holiday grant for YYYY"`
- **Idempotent:** Skips if a `yearly_grant` entry already exists for the user+workspace in the current year

```ruby
# config/recurring.yml
holiday_yearly_grant:
  class: HolidayYearlyGrantJob
  schedule: "0 0 1 1 *"  # January 1st at midnight
```

## Edge Cases

- **Weekends**: `business_days` counts only Mon-Fri. Weekends in the date range are excluded.
- **Public holidays**: Not handled in v1. Only weekday count matters.
- **Cancelling approved request**: Creates a reversal entry to restore balance. Both deduction and reversal visible in ledger.
- **Cancelling pending request**: No balance change. Just status update.
- **Employee leaves workspace**: Balance entries and requests persist for history. No dependent destroy.
- **Negative balance**: Only possible via admin adjustment (intentional). Employee requests validate `balance >= business_days`.
- **Overlapping requests**: Validated on create. No pending/approved overlap allowed for same user.
- **Past date requests**: Blocked on create. Admin can cancel past approved requests (reversal restores days).
- **Yearly grant idempotency**: Checks for existing yearly_grant in current year before creating. Safe to re-run.
