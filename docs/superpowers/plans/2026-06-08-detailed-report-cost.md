# Detailed Report Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show calculated labour cost (grand total + per-user) in the Detailed report HTML, admin-only, never in the PDF/CSV.

**Architecture:** Read-only feature over existing data. `TimeEntry#billable_amount_cents` already gives per-entry cost from snapshotted per-project member rates. The controller sums a `@total_cents`; the view renders a TOTAL COST card and per-user cost, gated on the existing `can_see_money?` helper. `ApplicationHelper#format_money` is extended to accept an optional currency.

**Tech Stack:** Rails 8.1.2, Minitest, Tailwind, Prawn (PDF — left untouched).

---

## File Structure

- **Helper** `app/helpers/application_helper.rb` — extend `format_money` to take an optional currency (default `$`-style, unchanged when no currency passed).
- **Controller** `app/controllers/reports/detaileds_controller.rb#show` — add `@total_cents`.
- **View** `app/views/reports/detaileds/show.html.erb` — TOTAL COST stat card + per-user cost in section header, both wrapped in `can_see_money?`.
- **Tests** `test/controllers/reports/detaileds_controller_test.rb` (new), `test/helpers/application_helper_test.rb` (new or appended).

### Facts verified against the codebase
- `TimeEntry#billable_amount_cents` = `(duration_seconds / 3600.0 * effective_rate_cents).round`. `effective_rate_cents` returns the entry's snapshotted `hourly_rate_cents` (set on save via `set_hourly_rate`), else the project-membership rate, else 0.
- `can_see_money?` is registered via `helper_method` (Authorization concern) → callable in the view. Returns `admin_or_owner?`.
- `format_money(cents)` already exists in `ApplicationHelper` returning `"$X.XX"`.
- No `time_entries.yml` fixture exists → tests must create entries in setup. Creating an entry with `stopped_at` present triggers `set_hourly_rate`, snapshotting the member's project rate.
- Fixtures: `projects(:jira_project)` currency `USD`; `project_memberships`: `one_elvium` (users(:one), jira_project, 15000¢ = $150/hr), `two_elvium` (users(:two), jira_project, 10000¢ = $100/hr). `users(:one)` is owner of `workspaces(:one)`; `users(:two)` employee.
- Detailed view stat cards use `.stat-card`/`.stat-label`/`.stat-number` (lines ~44-53). Per-user header computes `user_total` (seconds) + `user_pct` inline (lines ~56-68).

---

### Task 1: Extend `format_money` to accept an optional currency

**Files:**
- Modify: `app/helpers/application_helper.rb` (the existing `format_money`)
- Test: `test/helpers/application_helper_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/helpers/application_helper_test.rb`:

```ruby
require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "format_money without a currency keeps the dollar style" do
    assert_equal "$150.00", format_money(15_000)
    assert_equal "$0.00", format_money(nil)
  end

  test "format_money with a currency appends a delimited amount and code" do
    assert_equal "150.00 USD", format_money(15_000, "USD")
    assert_equal "1,234.50 USD", format_money(123_450, "USD")
  end

  test "format_money with a currency treats nil cents as zero" do
    assert_equal "0.00 USD", format_money(nil, "USD")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/application_helper_test.rb`
Expected: FAIL — the currency-argument tests error (`wrong number of arguments`) since `format_money` currently takes one arg.

- [ ] **Step 3: Implement the change**

In `app/helpers/application_helper.rb`, replace the existing `format_money`:

```ruby
  def format_money(cents)
    return "$0.00" if cents.nil?
    "$#{'%.2f' % (cents / 100.0)}"
  end
```

with:

```ruby
  # Without a currency: dollar-prefixed (legacy callers). With a currency code:
  # a delimited amount followed by the code, e.g. "1,234.50 USD". Used by the
  # Detailed report, where amounts are summed per project currency (or shown
  # without a symbol when projects/currencies are mixed).
  def format_money(cents, currency = nil)
    amount = cents.to_i / 100.0
    if currency.present?
      "#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', amount))} #{currency}"
    else
      "$#{'%.2f' % amount}"
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/helpers/application_helper_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Verify no existing caller broke**

Run: `grep -rn "format_money" app/`
Expected: existing single-arg calls still valid (the second arg is optional). No code change needed at call sites.

- [ ] **Step 6: Commit**

```bash
git add app/helpers/application_helper.rb test/helpers/application_helper_test.rb
git commit -m "feat: format_money supports an optional currency code"
```

---

### Task 2: Compute `@total_cents` in the Detailed controller

**Files:**
- Modify: `app/controllers/reports/detaileds_controller.rb` (`show`, after `@total_seconds`)
- Test: `test/controllers/reports/detaileds_controller_test.rb`

> Note: `assigns()` is NOT available in this project (no `rails-controller-testing`
> gem). Tests assert through the rendered response body instead. Task 2 also
> verifies the per-entry cost math at the model level so the dollar figures the
> view asserts in Task 3 are grounded.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/reports/detaileds_controller_test.rb`:

```ruby
require "test_helper"

class Reports::DetailedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project) # currency USD
    @day = Date.new(2026, 5, 4)

    # users(:one) @ $150/hr, users(:two) @ $100/hr on jira_project (from fixtures).
    # 2h for user one => $300.00 = 30_000¢ ; 1h for user two => $100.00 = 10_000¢.
    @entry_one = create_entry(users(:one), start: @day.to_time + 9.hours, hours: 2)
    @entry_two = create_entry(users(:two), start: @day.to_time + 9.hours, hours: 1)

    sign_in_as(users(:one)) # owner / admin
  end

  test "per-entry billable amounts match the fixture rates" do
    # Sanity: entries snapshot the member project rate at save time.
    assert_equal 30_000, @entry_one.billable_amount_cents # 2h @ $150
    assert_equal 10_000, @entry_two.billable_amount_cents # 1h @ $100
  end

  test "show renders successfully for an admin" do
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
  end

  private

  def create_entry(user, start:, hours:)
    @workspace.time_entries.create!(
      user: user,
      project: @project,
      started_at: start,
      stopped_at: start + hours.hours
    )
  end
end
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `bin/rails test test/controllers/reports/detaileds_controller_test.rb`
Expected: the "per-entry billable amounts" test PASSES (model math is already implemented); the "show renders" test PASSES (route exists). This task's test is a guard for the fixture math the view will rely on. If the billable-amounts test fails, stop — the fixtures or rate snapshotting differ from assumptions and Task 3's dollar assertions would be wrong.

- [ ] **Step 3: Add `@total_cents` to the controller**

In `app/controllers/reports/detaileds_controller.rb`, the `show` action has:

```ruby
      @total_seconds = scope.sum(:duration_seconds)
```

Add immediately after it:

```ruby
      # Per-entry cost uses each entry's snapshotted rate (set at stop time);
      # summed in Ruby over the already-loaded entries. Shown only to admins.
      @total_cents = @entries.sum(&:billable_amount_cents)
```

(`@entries = scope.order(started_at: :asc)` is assigned just above `@total_seconds`, so it is available.)

- [ ] **Step 4: Run test to verify it still passes**

Run: `bin/rails test test/controllers/reports/detaileds_controller_test.rb`
Expected: PASS (2 tests). `@total_cents` is now computed; its rendering is asserted in Task 3.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/reports/detaileds_controller.rb test/controllers/reports/detaileds_controller_test.rb
git commit -m "feat: compute total cost in the detailed report controller"
```

---

### Task 3: Render cost in the Detailed view (card + per-user header)

**Files:**
- Modify: `app/views/reports/detaileds/show.html.erb` (stat cards ~44-53; per-user header ~56-68)
- Test: `test/controllers/reports/detaileds_controller_test.rb` (append rendering assertions)

- [ ] **Step 1: Write the failing rendering tests**

Append inside the test class in `test/controllers/reports/detaileds_controller_test.rb` (before the `private` keyword):

```ruby
  test "admin sees a total cost card with the project currency" do
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
    assert_select ".stat-label", text: "Total Cost"
    assert_match "400.00 USD", response.body # 30_000 + 10_000 cents
  end

  test "admin sees per-user cost in the section header" do
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
    assert_match "300.00 USD", response.body # user one: 2h @ $150
    assert_match "100.00 USD", response.body # user two: 1h @ $100
  end

  test "employee cannot see the detailed report at all" do
    sign_in_as(users(:two)) # employee
    get reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_redirected_to root_path
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/reports/detaileds_controller_test.rb`
Expected: the two "admin sees …" tests FAIL (no "Total Cost" card / no currency strings yet). The employee test passes (existing `require_admin!`).

- [ ] **Step 3: Add the TOTAL COST stat card**

In `app/views/reports/detaileds/show.html.erb`, the stats block reads:

```erb
  <%# Stats %>
  <div class="flex gap-3">
    <div class="stat-card flex-1">
      <div class="stat-label">Total Hours</div>
      <div class="stat-number"><%= format_duration_hm(@total_seconds) %></div>
    </div>
    <div class="stat-card flex-1">
      <div class="stat-label">Team Members</div>
      <div class="stat-number"><%= @entries_by_user.size %></div>
    </div>
  </div>
```

Add a third card, gated on `can_see_money?`, after the Team Members card (still inside the flex row):

```erb
  <%# Stats %>
  <div class="flex gap-3">
    <div class="stat-card flex-1">
      <div class="stat-label">Total Hours</div>
      <div class="stat-number"><%= format_duration_hm(@total_seconds) %></div>
    </div>
    <div class="stat-card flex-1">
      <div class="stat-label">Team Members</div>
      <div class="stat-number"><%= @entries_by_user.size %></div>
    </div>
    <% if can_see_money? %>
      <div class="stat-card flex-1">
        <div class="stat-label">Total Cost</div>
        <div class="stat-number"><%= format_money(@total_cents, @project&.currency) %></div>
      </div>
    <% end %>
  </div>
```

- [ ] **Step 4: Add per-user cost to the section header**

The per-user header block reads:

```erb
    <% @entries_by_user.each do |user, entries| %>
      <% user_total = entries.sum(&:duration_seconds) %>
      <% user_pct = @total_seconds > 0 ? (user_total.to_f / @total_seconds * 100).round(1) : 0 %>

      <div class="m3-card-outlined overflow-hidden">
        <div class="px-4 py-3 border-b flex items-center justify-between" style="border-color: var(--color-outline-variant)">
          <h2 class="text-base font-bold" style="color: var(--color-on-surface)"><%= user.name %></h2>
          <div class="flex items-center gap-3">
            <span class="text-sm" style="color: var(--color-on-surface-variant)"><%= user_pct %>%</span>
            <span class="font-mono font-bold text-sm" style="color: var(--color-on-surface)">
              <%= format("%d:%02d", user_total / 3600, (user_total % 3600) / 60) %>
            </span>
          </div>
        </div>
```

Change it to add a `user_cost_cents` local and a cost span (gated on `can_see_money?`):

```erb
    <% @entries_by_user.each do |user, entries| %>
      <% user_total = entries.sum(&:duration_seconds) %>
      <% user_pct = @total_seconds > 0 ? (user_total.to_f / @total_seconds * 100).round(1) : 0 %>
      <% user_cost_cents = entries.sum(&:billable_amount_cents) %>

      <div class="m3-card-outlined overflow-hidden">
        <div class="px-4 py-3 border-b flex items-center justify-between" style="border-color: var(--color-outline-variant)">
          <h2 class="text-base font-bold" style="color: var(--color-on-surface)"><%= user.name %></h2>
          <div class="flex items-center gap-3">
            <span class="text-sm" style="color: var(--color-on-surface-variant)"><%= user_pct %>%</span>
            <span class="font-mono font-bold text-sm" style="color: var(--color-on-surface)">
              <%= format("%d:%02d", user_total / 3600, (user_total % 3600) / 60) %>
            </span>
            <% if can_see_money? %>
              <span class="font-mono font-bold text-sm" style="color: var(--color-primary)">
                <%= format_money(user_cost_cents, @project&.currency) %>
              </span>
            <% end %>
          </div>
        </div>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/reports/detaileds_controller_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 6: Build CSS (in case new utility classes are needed) and commit**

Run: `bin/rails tailwindcss:build`
Expected: builds without error (no new classes introduced beyond existing ones; this is a safety check).

```bash
git add app/views/reports/detaileds/show.html.erb test/controllers/reports/detaileds_controller_test.rb
git commit -m "feat: show total and per-user cost in the detailed report (admin-only)"
```

---

### Task 4: Confirm cost is absent from the PDF export

**Files:**
- Test: `test/controllers/reports/detaileds_controller_test.rb` (append)

- [ ] **Step 1: Write the test**

Append inside the test class (before `private`):

```ruby
  test "pdf export returns a pdf and does not embed the cost figures" do
    get export_pdf_reports_detailed_path(from: "2026-05-01", to: "2026-05-31", project_id: @project.id)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    # The HTML shows "400.00 USD" etc.; the PDF must not contain those strings.
    assert_no_match "400.00 USD", response.body
    assert_no_match "300.00 USD", response.body
  end
```

- [ ] **Step 2: Run the test**

Run: `bin/rails test test/controllers/reports/detaileds_controller_test.rb -n /pdf/`
Expected: PASS immediately — `export_pdf` was never modified, so it contains no cost. This test locks that in as a regression guard.

- [ ] **Step 3: Commit**

```bash
git add test/controllers/reports/detaileds_controller_test.rb
git commit -m "test: guard that detailed PDF export excludes cost"
```

---

### Task 5: Regression + deploy

**Files:** none (verification only)

- [ ] **Step 1: Run the touched tests together**

Run: `bin/rails test test/helpers/application_helper_test.rb test/controllers/reports/detaileds_controller_test.rb`
Expected: all PASS (3 + 6 = 9 tests), 0 failures.

- [ ] **Step 2: Run the full controller + model + helper suite**

Run: `bin/rails test test/controllers test/models test/helpers`
Expected: no NEW failures beyond the project's known pre-existing ones (claude_cli `--add-dir` ×3, jira_sync `fetch_all_comments`, holiday overlap). If a test that previously passed now fails, fix it before deploying.

- [ ] **Step 3: Push and deploy**

```bash
git push origin production
cap production deploy
```

Expected: deploy exits 0; `puma:stop` then `puma:start` succeed (full restart).

- [ ] **Step 4: Verify on production with Playwright**

- Log in as admin (kacper@rubyonsaas.com). Go to Reports → Detailed, pick a project with rates (e.g. Elvium) and a populated month.
- Confirm a **Total Cost** card appears next to Total Hours / Team Members, and each user's section header shows their cost (e.g. `… USD`).
- Click **PDF** → confirm the downloaded PDF shows hours but **no** cost.
- (If feasible) confirm a non-admin does not see Reports → Detailed at all.

---

## Notes for the implementer

- This feature reads existing data only — no migration, no schema change, no rate-setting UI (that already exists on Project → Members).
- `@project` is `nil` in the "All Projects" view → `format_money(cents, nil)` shows a neutral amount with no currency symbol, by design (mixed currencies, no FX).
- Keep `export_pdf` and `export_csv` untouched — that is what keeps cost out of those exports.
