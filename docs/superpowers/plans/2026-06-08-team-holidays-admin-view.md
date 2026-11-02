# Admin Team Holidays View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show admins/owners a "Team Holidays" section on the Holidays page listing every member's requests (all statuses), newest holiday first.

**Architecture:** Read-only surfacing of already-loaded data. The controller already assigns `@all_requests` for admins; reorder it by `start_date: :desc` and render it in a new, admin-gated view section reusing existing row markup and the `holiday_status_style` helper.

**Tech Stack:** Rails 8.1.2, Minitest, Tailwind.

---

## File Structure

- **Controller** `app/controllers/holiday_requests_controller.rb` — reorder `@all_requests` (`created_at` → `start_date`, desc).
- **View** `app/views/holiday_requests/index.html.erb` — add admin-only "Team Holidays" section after the "Team Time Off" block (~line 93) and before the "Balance History Link" block (~line 95).
- **Fixture** `test/fixtures/holiday_requests.yml` — add a cancelled request for the all-statuses test.
- **Test** `test/controllers/holiday_requests_controller_test.rb` (new).

### Facts verified against the codebase
- Controller assigns (admins only): `@all_requests = current_workspace.holiday_requests.includes(:user, :reviewed_by).order(created_at: :desc)`. No view consumes it today.
- `HolidayRequest`: `enum status { pending: 0, approved: 1, cancelled: 2 }`, `business_days` int, `start_date`/`end_date`, `belongs_to :user`. Helper `holiday_status_style(status)` exists and is used by "My Requests".
- `require_employee!` gates the controller; employees CAN reach index (they see their own), so the admin section must be guarded in the view by `current_user.admin_or_owner?(current_workspace)`.
- Existing fixtures (`test/fixtures/holiday_requests.yml`): `kacper_pending` (user one, 2026-05-04..08, pending), `kacper_approved` (user one, 2026-07-01..03, approved), `other_user_pending` (user two, 2026-06-15..19, pending).
- `users(:one)` = owner of `workspaces(:one)`; `users(:two)` = employee. `sign_in_as` helper available.
- View anchor: line 93 closes the `@team_upcoming` block; line 95 begins `<%# Balance History Link %>`.

---

### Task 1: Reorder `@all_requests` by start date

**Files:**
- Modify: `app/controllers/holiday_requests_controller.rb`
- Fixture: `test/fixtures/holiday_requests.yml`
- Test: `test/controllers/holiday_requests_controller_test.rb`

- [ ] **Step 1: Add a cancelled fixture for later tests**

Append to `test/fixtures/holiday_requests.yml`:

```yaml
other_user_cancelled:
  user: two
  workspace: one
  start_date: "2026-08-10"
  end_date: "2026-08-14"
  business_days: 5
  note: "Cancelled plan"
  status: 2
```

- [ ] **Step 2: Write the failing test**

Create `test/controllers/holiday_requests_controller_test.rb`:

```ruby
require "test_helper"

class HolidayRequestsControllerTest < ActionDispatch::IntegrationTest
  test "admin team holidays are ordered by start date descending" do
    sign_in_as(users(:one)) # owner
    get holiday_requests_path
    assert_response :success

    # Fixtures span 2026-05 (kacper_pending) .. 2026-08 (other_user_cancelled).
    # Newest start_date must appear before older ones in the rendered page.
    aug = response.body.index("Aug 10")
    jul = response.body.index("Jul 1")
    jun = response.body.index("Jun 15")
    may = response.body.index("May 4")
    assert aug && jul && jun && may, "expected all four holiday date ranges to render"
    assert aug < jul, "Aug request should render before Jul"
    assert jul < jun, "Jul request should render before Jun"
    assert jun < may, "Jun request should render before May"
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: FAIL — the "Team Holidays" section isn't rendered yet, so the date strings from other users' requests are absent (`aug`/`jun` nil) → assertion fails. (This task adds the controller order; Task 2 adds the rendering. The test fully passes after Task 2 — that is expected for this tightly-coupled view feature.)

- [ ] **Step 4: Apply the controller reorder**

In `app/controllers/holiday_requests_controller.rb`, the admin branch reads:

```ruby
      @all_requests = current_workspace.holiday_requests
        .includes(:user, :reviewed_by)
        .order(created_at: :desc)
```

Change `.order(created_at: :desc)` to `.order(start_date: :desc)`:

```ruby
      @all_requests = current_workspace.holiday_requests
        .includes(:user, :reviewed_by)
        .order(start_date: :desc)
```

- [ ] **Step 5: Commit (test still red until Task 2)**

```bash
git add app/controllers/holiday_requests_controller.rb test/fixtures/holiday_requests.yml test/controllers/holiday_requests_controller_test.rb
git commit -m "feat: order admin holiday requests by start date"
```

---

### Task 2: Render the admin "Team Holidays" section

**Files:**
- Modify: `app/views/holiday_requests/index.html.erb` (insert after line 93, before line 95)
- Test: `test/controllers/holiday_requests_controller_test.rb` (append)

- [ ] **Step 1: Append the rendering + permission tests**

Add inside the test class in `test/controllers/holiday_requests_controller_test.rb`:

```ruby
  test "admin sees the Team Holidays section with other members' requests" do
    sign_in_as(users(:one)) # owner
    get holiday_requests_path
    assert_response :success
    assert_select "h2", text: "Team Holidays"
    assert_match users(:two).name, response.body # another member's request shown
  end

  test "admin sees cancelled requests in Team Holidays" do
    sign_in_as(users(:one))
    get holiday_requests_path
    assert_response :success
    assert_match "cancelled", response.body # other_user_cancelled fixture
  end

  test "employee does not see the Team Holidays section" do
    sign_in_as(users(:two)) # employee
    get holiday_requests_path
    assert_response :success
    assert_select "h2", text: "Team Holidays", count: 0
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: the admin tests FAIL (no "Team Holidays" heading yet). The employee test passes vacuously.

- [ ] **Step 3: Insert the section into the view**

In `app/views/holiday_requests/index.html.erb`, find the end of the "Team upcoming holidays" block (the `<% end %>` on line 93, just before the `<%# Balance History Link %>` comment on line 95). Insert this between them:

```erb
  <%# Admin: full team holiday history (all statuses) %>
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

- [ ] **Step 4: Run the full test file to verify it passes**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: PASS (4 tests — the Task 1 ordering test now also passes because the section renders).

- [ ] **Step 5: Build CSS (safety) and commit**

Run: `bin/rails tailwindcss:build`
Expected: builds without error (no new classes beyond existing).

```bash
git add app/views/holiday_requests/index.html.erb test/controllers/holiday_requests_controller_test.rb
git commit -m "feat: admin Team Holidays section on the holidays page"
```

---

### Task 3: Regression + deploy

**Files:** none (verification only)

- [ ] **Step 1: Run the touched test file**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: 4 PASS, 0 failures.

- [ ] **Step 2: Run the holiday model test (fixture sanity) and full controller suite**

Run: `bin/rails test test/controllers test/models/holiday_request_test.rb`
Expected: no NEW failures beyond the known pre-existing ones (the holiday overlap test `test_valid_when_overlapping_with_cancelled_request` already fails on its own; the new `other_user_cancelled` fixture is in a different date range — confirm the count of failures didn't increase beyond that single known one).

- [ ] **Step 3: Push and deploy**

```bash
git push origin production
cap production deploy
```

Expected: deploy exits 0; full puma stop/start.

- [ ] **Step 4: Verify on production with Playwright**

- Log in as admin (kacper@rubyonsaas.com). Go to Holidays.
- Confirm a **Team Holidays** section appears listing members (names, date ranges, day counts, status pills), including past and cancelled entries, newest start date first.

---

## Notes for the implementer

- Data is already loaded — no new query beyond the reorder. The section is admin/owner-gated in the view; employees reaching the page (for their own requests) never see it.
- Section is hidden entirely when `@all_requests` is empty (no empty-state card).
- The `@all_requests` reorder is safe: this section is its only consumer.
