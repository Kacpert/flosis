# Workspace Restructure Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the Gold time-tracking app to move currency and rates to project level, introduce project memberships with per-person hourly rates and rate history, remove workspace settings, and enforce role-based project visibility.

**Architecture:** Two new tables (`project_memberships`, `rate_changes`) link users to projects with rates. Workspace settings page is removed; sidebar/controllers enforce admin-only access to Manage/Reports sections. Project page gets Settings/Members tabs. The billable concept is removed entirely — all time is billable.

**Tech Stack:** Rails 8.1.2, Ruby 3.4.1, Minitest, Turbo/Stimulus, Tailwind CSS with DaisyUI

**Spec:** `docs/superpowers/specs/2026-03-15-workspace-restructure-design.md`

---

## Chunk 1: Database Schema & Models

### Task 1: Create project_memberships table and model

**Files:**
- Create: `db/migrate/TIMESTAMP_create_project_memberships.rb`
- Create: `app/models/project_membership.rb`
- Create: `test/models/project_membership_test.rb`
- Create: `test/fixtures/project_memberships.yml`

- [ ] **Step 1: Write the test for ProjectMembership model**

```ruby
# test/models/project_membership_test.rb
require "test_helper"

class ProjectMembershipTest < ActiveSupport::TestCase
  test "validates uniqueness of user per project" do
    existing = project_memberships(:one_elvium)
    duplicate = ProjectMembership.new(
      project: existing.project,
      user: existing.user,
      hourly_rate_cents: 5000
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "belongs to project and user" do
    pm = project_memberships(:one_elvium)
    assert_equal projects(:jira_project), pm.project
    assert_equal users(:one), pm.user
  end

  test "defaults hourly_rate_cents to 0" do
    pm = ProjectMembership.new(project: projects(:plain_project), user: users(:two))
    assert_equal 0, pm.hourly_rate_cents
  end
end
```

- [ ] **Step 2: Create fixtures**

```yaml
# test/fixtures/project_memberships.yml
one_elvium:
  project: jira_project
  user: one
  hourly_rate_cents: 15000

two_elvium:
  project: jira_project
  user: two
  hourly_rate_cents: 10000

one_internal:
  project: plain_project
  user: one
  hourly_rate_cents: 12000
```

- [ ] **Step 3: Generate migration**

Run: `bin/rails generate migration CreateProjectMemberships project:references user:references hourly_rate_cents:integer`

Then edit the migration:

```ruby
class CreateProjectMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :project_memberships do |t|
      t.references :project, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :hourly_rate_cents, null: false, default: 0

      t.timestamps
    end

    add_index :project_memberships, [:project_id, :user_id], unique: true
  end
end
```

- [ ] **Step 4: Create the model**

```ruby
# app/models/project_membership.rb
class ProjectMembership < ApplicationRecord
  belongs_to :project
  belongs_to :user

  validates :user_id, uniqueness: { scope: :project_id }
end
```

- [ ] **Step 5: Run migration and tests**

Run: `bin/rails db:migrate && bin/rails test test/models/project_membership_test.rb`
Expected: 3 tests, 3 passes

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add project_memberships table and model"
```

---

### Task 2: Create rate_changes table and model

**Files:**
- Create: `db/migrate/TIMESTAMP_create_rate_changes.rb`
- Create: `app/models/rate_change.rb`
- Create: `test/models/rate_change_test.rb`
- Create: `test/fixtures/rate_changes.yml`

- [ ] **Step 1: Write the test**

```ruby
# test/models/rate_change_test.rb
require "test_helper"

class RateChangeTest < ActiveSupport::TestCase
  test "belongs to project_membership" do
    rc = rate_changes(:one_elvium_initial)
    assert_equal project_memberships(:one_elvium), rc.project_membership
  end

  test "tracks who changed the rate" do
    rc = rate_changes(:one_elvium_initial)
    assert_equal users(:one), rc.changed_by
  end

  test "initial rate has nil previous_rate_cents" do
    rc = rate_changes(:one_elvium_initial)
    assert_nil rc.previous_rate_cents
  end
end
```

- [ ] **Step 2: Create fixtures**

```yaml
# test/fixtures/rate_changes.yml
one_elvium_initial:
  project_membership: one_elvium
  hourly_rate_cents: 15000
  previous_rate_cents:
  changed_by: one
  changed_at: <%= 30.days.ago.iso8601 %>
```

- [ ] **Step 3: Generate migration**

Run: `bin/rails generate migration CreateRateChanges project_membership:references hourly_rate_cents:integer previous_rate_cents:integer changed_by:references changed_at:datetime`

Then edit the migration:

```ruby
class CreateRateChanges < ActiveRecord::Migration[8.0]
  def change
    create_table :rate_changes do |t|
      t.references :project_membership, null: false, foreign_key: true
      t.integer :hourly_rate_cents, null: false
      t.integer :previous_rate_cents
      t.references :changed_by, foreign_key: { to_table: :users }
      t.datetime :changed_at, null: false

      t.timestamps
    end
  end
end
```

- [ ] **Step 4: Create the model**

```ruby
# app/models/rate_change.rb
class RateChange < ApplicationRecord
  belongs_to :project_membership
  belongs_to :changed_by, class_name: "User", optional: true
end
```

- [ ] **Step 5: Run migration and tests**

Run: `bin/rails db:migrate && bin/rails test test/models/rate_change_test.rb`
Expected: 3 tests, 3 passes

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add rate_changes table and model"
```

---

### Task 3: Add currency to projects, wire up model associations

**Files:**
- Create: `db/migrate/TIMESTAMP_add_currency_to_projects.rb`
- Modify: `app/models/project.rb`
- Modify: `app/models/user.rb`
- Modify: `app/models/workspace_membership.rb`

- [ ] **Step 1: Generate migration**

Run: `bin/rails generate migration AddCurrencyToProjects currency:string`

Edit the migration:

```ruby
class AddCurrencyToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :currency, :string, limit: 3, default: "USD", null: false
  end
end
```

- [ ] **Step 2: Run migration**

Run: `bin/rails db:migrate`

- [ ] **Step 3: Add associations to Project model**

In `app/models/project.rb`, add after `has_many :time_entries, dependent: :nullify` (line 5):

```ruby
  has_many :project_memberships, dependent: :destroy
  has_many :members, through: :project_memberships, source: :user
```

Also add currency list constant after `PROJECT_COLORS`:

```ruby
  CURRENCIES = %w[USD EUR GBP CAD AUD JPY CHF PLN].freeze
```

- [ ] **Step 4: Add associations to User model**

In `app/models/user.rb`, add after `has_many :time_entries` (line 6):

```ruby
  has_many :project_memberships, dependent: :destroy
```

- [ ] **Step 5: Add associations and cascade callback to WorkspaceMembership**

In `app/models/workspace_membership.rb`, add after `belongs_to :workspace` (line 3):

```ruby
  before_destroy :destroy_project_memberships

  private

  def destroy_project_memberships
    ProjectMembership.where(user_id: user_id, project_id: workspace.project_ids).destroy_all
  end
```

- [ ] **Step 6: Add dependent destroy to ProjectMembership**

In `app/models/project_membership.rb`, add after `belongs_to :user`:

```ruby
  has_many :rate_changes, dependent: :destroy
```

- [ ] **Step 7: Write test for workspace membership cascade**

Add to `test/models/project_membership_test.rb`:

```ruby
  test "destroying workspace membership destroys project memberships" do
    ws_membership = workspace_memberships(:two_employee)
    user = users(:two)
    # two_elvium fixture exists
    assert ProjectMembership.exists?(user: user, project: projects(:jira_project))

    ws_membership.destroy

    assert_not ProjectMembership.exists?(user: user, project: projects(:jira_project))
  end
```

- [ ] **Step 8: Run all tests**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: add currency to projects, wire up model associations"
```

---

### Task 4: Rate change tracking callback on ProjectMembership

**Files:**
- Modify: `app/models/project_membership.rb`
- Modify: `test/models/project_membership_test.rb`

- [ ] **Step 1: Write tests for rate tracking**

Add to `test/models/project_membership_test.rb`:

```ruby
  test "creates rate_change on create" do
    pm = ProjectMembership.create!(
      project: projects(:plain_project),
      user: users(:two),
      hourly_rate_cents: 5000
    )
    assert_equal 1, pm.rate_changes.count
    rc = pm.rate_changes.first
    assert_equal 5000, rc.hourly_rate_cents
    assert_nil rc.previous_rate_cents
  end

  test "creates rate_change on rate update" do
    pm = project_memberships(:one_elvium)
    assert_difference "RateChange.count", 1 do
      pm.update!(hourly_rate_cents: 20000)
    end
    rc = pm.rate_changes.order(:created_at).last
    assert_equal 20000, rc.hourly_rate_cents
    assert_equal 15000, rc.previous_rate_cents
  end

  test "does not create rate_change when rate unchanged" do
    pm = project_memberships(:one_elvium)
    assert_no_difference "RateChange.count" do
      pm.update!(updated_at: Time.current)
    end
  end
```

- [ ] **Step 2: Run tests to see them fail**

Run: `bin/rails test test/models/project_membership_test.rb`
Expected: 3 new tests FAIL

- [ ] **Step 3: Add callback to ProjectMembership**

In `app/models/project_membership.rb`:

```ruby
class ProjectMembership < ApplicationRecord
  belongs_to :project
  belongs_to :user
  has_many :rate_changes, dependent: :destroy

  validates :user_id, uniqueness: { scope: :project_id }

  after_create :record_initial_rate
  after_update :record_rate_change, if: :saved_change_to_hourly_rate_cents?

  private

  def record_initial_rate
    rate_changes.create!(
      hourly_rate_cents: hourly_rate_cents,
      previous_rate_cents: nil,
      changed_by: Current.user,
      changed_at: Time.current
    )
  end

  def record_rate_change
    rate_changes.create!(
      hourly_rate_cents: hourly_rate_cents,
      previous_rate_cents: hourly_rate_cents_before_last_save,
      changed_by: Current.user,
      changed_at: Time.current
    )
  end
end
```

- [ ] **Step 4: Verify Current.user works**

`app/models/current.rb` delegates `:user` to `:session`. Do NOT modify it. Verify `Current.user` returns the logged-in user in a console or test. The `changed_by: Current.user` in the callbacks will work via this existing delegate.

- [ ] **Step 5: Run tests**

Run: `bin/rails test test/models/project_membership_test.rb`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: auto-track rate changes on project membership"
```

---

## Chunk 2: Remove Billable & Workspace Settings, Simplify Rate Hierarchy

### Task 5: Rewrite TimeEntry rate logic to use project membership

**Files:**
- Modify: `app/models/time_entry.rb`
- Modify: `test/models/project_membership_test.rb` (add time entry rate test)

- [ ] **Step 1: Write test for new rate resolution**

Create `test/models/time_entry_test.rb`:

```ruby
# test/models/time_entry_test.rb
require "test_helper"

class TimeEntryTest < ActiveSupport::TestCase
  test "effective_rate_cents returns project membership rate" do
    entry = TimeEntry.new(
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: Time.current
    )
    # one_elvium fixture has hourly_rate_cents: 15000
    assert_equal 15000, entry.effective_rate_cents
  end

  test "effective_rate_cents returns 0 when no membership" do
    entry = TimeEntry.new(
      user: users(:two),
      project: projects(:plain_project),
      workspace: workspaces(:one),
      started_at: Time.current
    )
    assert_equal 0, entry.effective_rate_cents
  end

  test "effective_rate_cents prefers entry own rate" do
    entry = TimeEntry.new(
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: Time.current,
      hourly_rate_cents: 99999
    )
    assert_equal 99999, entry.effective_rate_cents
  end

  test "set_hourly_rate locks rate from membership on stop" do
    entry = TimeEntry.create!(
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: 1.hour.ago,
      stopped_at: Time.current
    )
    assert_equal 15000, entry.hourly_rate_cents
  end

  test "billable_amount_cents calculates without billable check" do
    entry = TimeEntry.new(
      duration_seconds: 3600,
      hourly_rate_cents: 10000,
      user: users(:one),
      project: projects(:jira_project),
      workspace: workspaces(:one),
      started_at: 1.hour.ago,
      stopped_at: Time.current
    )
    assert_equal 10000, entry.billable_amount_cents
  end
end
```

- [ ] **Step 2: Run tests to see them fail**

Run: `bin/rails test test/models/time_entry_test.rb`
Expected: Several FAIL (effective_rate_cents still uses old chain)

- [ ] **Step 3: Rewrite TimeEntry model**

Replace the relevant methods in `app/models/time_entry.rb`:

Change line 4 from `belongs_to :project, optional: true` to:
```ruby
  belongs_to :project
```

Remove line 14 (the `inherit_billable_from_project` callback):
```ruby
  before_save :inherit_billable_from_project, if: -> { project_id_changed? && project.present? }
```

Remove line 20 (the billable scope):
```ruby
  scope :billable, -> { where(billable: true) }
```

Replace `effective_rate_cents` (lines 43-49) with:
```ruby
  def effective_rate_cents
    return hourly_rate_cents unless hourly_rate_cents.nil?
    ProjectMembership.find_by(project_id: project_id, user_id: user_id)&.hourly_rate_cents || 0
  end
```

Replace `billable_amount_cents` (lines 51-54) with:
```ruby
  def billable_amount_cents
    (duration_seconds / 3600.0 * effective_rate_cents).round
  end
```

Remove `inherit_billable_from_project` method (lines 78-80):
```ruby
  def inherit_billable_from_project
    self.billable = project.billable
  end
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/models/time_entry_test.rb`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: rewrite TimeEntry rate logic to use project membership"
```

---

### Task 6: Remove billable from across the codebase

**Files:**
- Modify: `app/models/project.rb:34-35` — remove `.where(billable: true)` from `budget_used_cents`
- Modify: `app/models/project.rb:26-28` — remove `effective_hourly_rate_cents` method
- Modify: `app/models/task.rb:12-14` — remove `effective_hourly_rate_cents` method
- Modify: `app/controllers/timers_controller.rb:19` — remove billable logic
- Modify: `app/controllers/timesheets_controller.rb:69` — remove billable logic
- Modify: `app/controllers/time_entries_controller.rb:18-19,112-113,134-136,139-140` — remove billable params/actions
- Modify: `app/controllers/dashboard_controller.rb:23,33,48-50` — remove billable scope usage, hardcode week start
- Modify: `app/controllers/reports/summaries_controller.rb:13-14,122` — remove billable scope/filter
- Modify: `app/controllers/reports/detaileds_controller.rb:13-14,44,46,72-73,87,104` — remove billable scope/filter
- Modify: `app/views/projects/_form.html.erb:32-35,37-45` — remove billable checkbox and hourly rate field
- Modify: `app/views/time_entries/_time_entry_row.html.erb:90` — remove billable checkbox
- Modify: `app/views/time_entries/_form.html.erb:65` — remove billable checkbox
- Modify: `app/views/time_entries/index.html.erb:18-20,92` — remove billable filter and bulk toggle
- Modify: `app/views/reports/summaries/show.html.erb:34` — remove billable filter
- Modify: `app/views/reports/detaileds/show.html.erb:39` — remove billable filter
- Modify: `app/views/dashboard/show.html.erb:47-48` — update labels (no "billable" distinction)
- Modify: `app/views/projects/index.html.erb` — remove billable column if present
- Modify: `app/views/projects/show.html.erb` — remove billable display if present

- [ ] **Step 1: Remove billable from Project model**

In `app/models/project.rb`:
- Remove `effective_hourly_rate_cents` method (lines 26-28)
- In `budget_used_cents` (line 35), change:
  ```ruby
  time_entries.where.not(stopped_at: nil).where(billable: true).sum(...)
  ```
  to:
  ```ruby
  time_entries.where.not(stopped_at: nil).sum("duration_seconds * COALESCE(hourly_rate_cents, 0) / 3600")
  ```

- [ ] **Step 2: Remove effective_hourly_rate_cents from Task model**

In `app/models/task.rb`, remove the `effective_hourly_rate_cents` method (lines 12-14).

- [ ] **Step 3: Remove billable from TimersController**

In `app/controllers/timers_controller.rb`, line 19, remove:
```ruby
      billable: params[:project_id].present? ? Project.find_by(id: params[:project_id])&.billable : true,
```

- [ ] **Step 4: Remove billable from TimesheetsController**

In `app/controllers/timesheets_controller.rb`, line 69, remove:
```ruby
        billable: Project.find(project_id).billable
```

- [ ] **Step 5: Remove billable from TimeEntriesController**

In `app/controllers/time_entries_controller.rb`:
- Remove billable filter (lines 18-20):
  ```ruby
  if params[:billable].present?
    scope = scope.where(billable: params[:billable] == "1")
  end
  ```
- Remove `toggle_billable` case (lines 112-113):
  ```ruby
  when "toggle_billable"
    entries.each { |e| e.update(billable: !e.billable?) }
  ```
- Remove `:billable` from `time_entry_params` (line 136)
- Remove `:billable` from `bulk_params` (line 140)

- [ ] **Step 6: Update DashboardController**

In `app/controllers/dashboard_controller.rb`:
- Line 23: Change `@week_billable_seconds = @week_entries.billable.sum(:duration_seconds)` to `@week_total_seconds = @week_entries.sum(:duration_seconds)` (same as `@week_seconds`, so just remove this line)
- Line 33: Change `@billable_amount = @week_entries.billable.sum(...)` to `@billable_amount = @week_entries.sum("time_entries.duration_seconds * COALESCE(time_entries.hourly_rate_cents, 0) / 360000.0")`
- Lines 48-50: Replace `start_day` method with:
  ```ruby
  def start_day
    :monday
  end
  ```

- [ ] **Step 7: Update report controllers**

In `app/controllers/reports/summaries_controller.rb`:
- Lines 13-14: Change `.billable.sum(...)` to `.sum(...)` (remove `.billable` scope calls)
- Line 122: Remove billable filter line

In `app/controllers/reports/detaileds_controller.rb`:
- Lines 13-14: Change `.billable.sum(...)` to `.sum(...)` (remove `.billable` scope calls)
- Line 104: Remove billable filter line
- Line 30: Remove "Billable" from CSV header array
- Line 44: Remove `entry.billable? ? "Yes" : "No"` from CSV row
- Line 46: Keep `entry.billable_amount` (method still works, just remove billable guard)
- Line 65: Remove "Billable" from PDF header
- Lines 72-73: Remove `entry.billable?` ternary from PDF row
- Line 87: `entries.sum(&:billable_amount)` still works after method change
- Line 90: Update "Billable Amount" label to "Amount" in PDF

- [ ] **Step 8: Remove billable from views**

In `app/views/projects/_form.html.erb`:
- Remove the billable checkbox (lines 32-35)
- Remove the hourly rate field (lines 37-45)

In `app/views/time_entries/_time_entry_row.html.erb`:
- Remove the billable checkbox (around line 90)

In `app/views/time_entries/_form.html.erb`:
- Remove the billable checkbox (around line 65)

In `app/views/time_entries/index.html.erb`:
- Remove billable filter (around lines 18-20 in the filter form)
- Remove toggle_billable bulk action (line 92)

In `app/views/reports/summaries/show.html.erb`:
- Remove billable filter dropdown (around line 34)
- Update "Billable Hours" label to "Total Hours" (around line 49)

In `app/views/reports/detaileds/show.html.erb`:
- Remove billable filter dropdown (around line 39)
- Update "Billable Hours" label to "Total Hours" (around line 54)
- Remove billable amount per entry (around line 104)

In `app/views/dashboard/show.html.erb`:
- Line 47: Replace `@week_billable_seconds` with `@week_seconds` (all entries are billable now, so total = billable)
- Update "Billable Hours" label to "Total Hours" (around line 47)
- Keep the amount display (around line 48), update label from "Billable" if present
- Lines 16-18, 55: Wrap "Create Project" link and "View all" projects link in `admin_or_owner?` check

In `app/views/projects/index.html.erb`:
- Lines 33-35: Remove the billable badge (`if project.billable?` conditional)

In `app/views/projects/show.html.erb`:
- Line 29: Remove `@project.billable?` stat display (this file gets fully rewritten in Task 10, but if Task 6 runs first, remove this reference)

In `app/views/reports/detaileds/show.html.erb`:
- Line 104: Change `<% if entry.billable? %>$<%= '%.2f' % entry.billable_amount %><% end %>` to just `$<%= '%.2f' % entry.billable_amount %>`

- [ ] **Step 9: Run all tests**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "refactor: remove billable concept, simplify rate hierarchy"
```

---

### Task 7: Remove workspace settings page and clean up workspace model

**Files:**
- Delete: `app/controllers/workspace_settings_controller.rb`
- Delete: `app/views/workspace_settings/show.html.erb`
- Modify: `app/models/workspace.rb` — remove `time_format` enum
- Modify: `app/controllers/workspaces_controller.rb:27` — clean up permitted params
- Modify: `app/views/layouts/application.html.erb:116-125,164-166` — remove workspace settings links
- Modify: `config/routes.rb:17` — remove workspace_settings route
- Modify: `app/views/profiles/show.html.erb:33-39` — remove hourly rate field

- [ ] **Step 1: Remove workspace settings route**

In `config/routes.rb`, remove line 17:
```ruby
  resource :workspace_settings, only: [ :show, :update ]
```

- [ ] **Step 2: Delete workspace settings controller and view**

```bash
rm app/controllers/workspace_settings_controller.rb
rm -rf app/views/workspace_settings
```

- [ ] **Step 3: Remove workspace settings links from sidebar**

In `app/views/layouts/application.html.erb`:
- Remove the Settings section in the sidebar (lines 116-125):
  ```erb
  <% if current_user.admin_or_owner?(current_workspace) %>
    <div class="pt-7 pb-2">
      <div class="m3-nav-section">Settings</div>
    </div>
    <%= link_to workspace_settings_path, ... %>
  <% end %>
  ```
- Remove "Workspace Settings" from the user menu (lines 164-166):
  ```erb
  <% if current_user.admin_or_owner?(current_workspace) %>
    <%= link_to "Workspace Settings", workspace_settings_path, class: "m3-menu-item" %>
  <% end %>
  ```

- [ ] **Step 4: Clean up Workspace model**

In `app/models/workspace.rb`, remove line 10:
```ruby
  enum :time_format, { twenty_four_hour: 0, twelve_hour: 1 }
```

- [ ] **Step 5: Clean up WorkspacesController**

In `app/controllers/workspaces_controller.rb`, line 27, change:
```ruby
  params.require(:workspace).permit(:name, :default_currency, :week_start, :time_format)
```
to:
```ruby
  params.require(:workspace).permit(:name)
```

- [ ] **Step 6: Remove hourly rate from profile page**

In `app/views/profiles/show.html.erb`, remove lines 33-39 (the default hourly rate field).

In `app/controllers/profiles_controller.rb`:
- Remove `:default_hourly_rate_dollars` from permitted params (line 16)
- Remove the dollars-to-cents conversion (lines 19-22)

- [ ] **Step 7: Run all tests**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "refactor: remove workspace settings page and user default rate"
```

---

## Chunk 3: Permissions & Navigation

### Task 8: Enforce role-based sidebar and controller authorization

**Files:**
- Modify: `app/views/layouts/application.html.erb` — wrap Manage and Reports in admin check, show Tags separately
- Modify: `app/controllers/reports/summaries_controller.rb` — add `require_admin!`
- Modify: `app/controllers/reports/detaileds_controller.rb` — add `require_admin!`
- Modify: `app/controllers/reports/weeklies_controller.rb` — add `require_admin!`
- Modify: `app/controllers/authorization.rb:26` — fix redirect for `require_employee!`

- [ ] **Step 1: Write authorization tests**

Create `test/controllers/authorization_test.rb`:

```ruby
# test/controllers/authorization_test.rb
require "test_helper"

class AuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @employee = users(:two)
    @workspace = workspaces(:one)
  end

  test "employee cannot access projects index" do
    sign_in_as @employee
    get projects_path
    assert_redirected_to root_path
  end

  test "employee cannot access reports summary" do
    sign_in_as @employee
    get reports_summary_path
    assert_redirected_to root_path
  end

  test "admin can access projects index" do
    sign_in_as @owner
    get projects_path
    assert_response :success
  end

  test "admin can access reports summary" do
    sign_in_as @owner
    get reports_summary_path
    assert_response :success
  end

  private

  def sign_in_as(user)
    post session_path, params: {
      email_address: user.email_address,
      password: "password"
    }
  end
end
```

- [ ] **Step 2: Verify and add require_admin! to controllers**

Note: `ProjectsController` and `ClientsController` already have `before_action :require_admin!` — verify this is in place. Only the report controllers need it added:

In `app/controllers/reports/summaries_controller.rb`, add after `include WorkspaceScoped`:
```ruby
    before_action :require_admin!
```

In `app/controllers/reports/detaileds_controller.rb`, add after `include WorkspaceScoped`:
```ruby
    before_action :require_admin!
```

In `app/controllers/reports/weeklies_controller.rb`, add after `include WorkspaceScoped`:
```ruby
    before_action :require_admin!
```

- [ ] **Step 3: Fix require_employee! redirect**

In `app/controllers/concerns/authorization.rb`, line 26, change the redirect from `reports_summary_path` to `root_path` (since employees can't access reports anymore):

```ruby
  def require_employee!
    unless current_user&.at_least_employee?(current_workspace)
      redirect_to root_path, alert: "You don't have permission to access this page."
    end
  end
```

- [ ] **Step 4: Update sidebar for role-based visibility**

In `app/views/layouts/application.html.erb`, restructure the nav section (lines 62-95). The new structure:

After the Timesheet link (line 60, end of the `unless client_role` block):

```erb
            <% if current_user.admin_or_owner?(current_workspace) %>
              <div class="pt-7 pb-2">
                <div class="m3-nav-section">Manage</div>
              </div>

              <%= link_to projects_path, ... %>
              <%= link_to clients_path, ... %>
              <%= link_to workspace_members_path, ... %>
            <% end %>

            <% unless current_user.client_role?(current_workspace) %>
              <% unless current_user.admin_or_owner?(current_workspace) %>
                <div class="pt-7 pb-2">
                  <div class="m3-nav-section">&nbsp;</div>
                </div>
              <% end %>

              <%= link_to tags_path, ... %>
            <% end %>

            <% if current_user.admin_or_owner?(current_workspace) %>
              <div class="pt-7 pb-2">
                <div class="m3-nav-section">Reports</div>
              </div>

              <%= link_to reports_summary_path, ... %>
              <%= link_to reports_detailed_path, ... %>
              <%= link_to reports_weekly_path, ... %>
            <% end %>
```

Key change: Tags is shown to all non-client users (outside the Manage block). Reports section is wrapped in `admin_or_owner?` check.

- [ ] **Step 5: Run tests**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: enforce role-based sidebar and controller authorization"
```

---

### Task 9: Filter project dropdown by membership for employees

**Files:**
- Modify: `app/views/shared/_timer_bar.html.erb:26,78-79,137-138` — filter project select
- Modify: `app/controllers/time_entries_controller.rb:33,40,56,63,91` — filter @projects
- Modify: `app/controllers/timesheets_controller.rb:15` — filter @projects
- Modify: `app/controllers/timers_controller.rb` — validate membership
- Modify: `app/controllers/timesheets_controller.rb` — validate membership
- Modify: `app/controllers/concerns/workspace_scoped.rb` or create helper

- [ ] **Step 1: Add a helper method for available projects**

In `app/controllers/concerns/workspace_scoped.rb`, add a helper:

```ruby
  def available_projects
    if current_user.admin_or_owner?(current_workspace)
      current_workspace.projects.active.order(:name)
    else
      current_workspace.projects.active
        .joins(:project_memberships)
        .where(project_memberships: { user_id: current_user.id })
        .order(:name)
    end
  end
  helper_method :available_projects
```

- [ ] **Step 2: Update timer bar to use available_projects**

In `app/views/shared/_timer_bar.html.erb`, replace all instances of:
```ruby
Current.workspace&.projects&.active&.order(:name) || []
```
with:
```ruby
available_projects
```

This appears on lines 26, 79, and 138. Note: these are inside `options_from_collection_for_select()` calls — replace the first argument (the collection) with `available_projects`.

Also update `app/views/time_entries/_time_entry_row.html.erb` — around line 79, the inline edit form also queries `Current.workspace&.projects&.active&.order(:name) || []` for its project dropdown. Replace with `available_projects`.

- [ ] **Step 3: Update TimeEntriesController to use available_projects**

In `app/controllers/time_entries_controller.rb`, replace:
```ruby
@projects = current_workspace.projects.active.order(:name)
```
with:
```ruby
@projects = available_projects
```

This appears on lines 33, 40, 56, 63, and 91.

- [ ] **Step 4: Update TimesheetsController to use available_projects**

In `app/controllers/timesheets_controller.rb`, line 15, change:
```ruby
@projects = current_workspace.projects.active.includes(:tasks).order(:name)
```
to:
```ruby
@projects = available_projects.includes(:tasks)
```

- [ ] **Step 5: Add membership validation for time entry creation**

In `app/controllers/timers_controller.rb`, add validation in the `start` method, before `create!`:

```ruby
  def start
    # Stop any existing running timer first
    existing = current_user.running_timer(current_workspace)
    if existing
      existing.update!(stopped_at: Time.current)
    end

    project = current_workspace.projects.find(params[:project_id]) if params[:project_id].present?

    unless current_user.admin_or_owner?(current_workspace) || project.nil?
      unless ProjectMembership.exists?(project: project, user: current_user)
        redirect_back fallback_location: root_path, alert: "You are not assigned to this project."
        return
      end
    end

    @time_entry = current_workspace.time_entries.create!(
      user: current_user,
      started_at: Time.current,
      description: params[:description],
      project_id: params[:project_id],
      task_id: params[:task_id],
      tag_ids: Array(params[:tag_ids])
    )

    redirect_back fallback_location: root_path
  end
```

- [ ] **Step 6: Add membership validation for timesheet cell updates**

In `app/controllers/timesheets_controller.rb`, add at the start of `update_cell`:

```ruby
  def update_cell
    project_id = params[:project_id]

    unless current_user.admin_or_owner?(current_workspace)
      unless ProjectMembership.exists?(project_id: project_id, user_id: current_user.id)
        redirect_to timesheet_path, alert: "You are not assigned to this project."
        return
      end
    end

    # ... rest of method
```

- [ ] **Step 7: Run all tests**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: filter project dropdown by membership for employees"
```

---

## Chunk 4: Project Settings Tabs & Members UI

### Task 10: Add project Settings/Members tabs

**Files:**
- Modify: `app/controllers/projects_controller.rb` — add `members` action, add `currency` to params
- Create: `app/controllers/project_memberships_controller.rb`
- Modify: `config/routes.rb` — add project_memberships routes
- Create: `app/views/projects/show.html.erb` — redesign with tabs
- Modify: `app/views/projects/_form.html.erb` — add currency field, remove billable/rate
- Create: `app/views/project_memberships/_member_row.html.erb`
- Create: `app/views/project_memberships/_rate_history.html.erb`

- [ ] **Step 1: Add routes for project memberships**

In `config/routes.rb`, update the projects resource:

```ruby
  resources :projects do
    resources :tasks, only: [ :create, :destroy ], shallow: true
    resources :project_memberships, only: [ :create, :update, :destroy ], path: "members"
    member do
      patch :archive
      patch :unarchive
      get :jira_tasks, to: "jira#jira_tasks"
      post :jira_sync, to: "jira#sync"
    end
  end
```

- [ ] **Step 2: Create ProjectMembershipsController**

```ruby
# app/controllers/project_memberships_controller.rb
class ProjectMembershipsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :set_project

  def create
    user = User.find(params[:user_id])
    @membership = @project.project_memberships.build(
      user: user,
      hourly_rate_cents: (params[:hourly_rate_dollars].to_f * 100).round
    )

    if @membership.save
      redirect_to project_path(@project, tab: "members"), notice: "#{user.name} added to project."
    else
      redirect_to project_path(@project, tab: "members"), alert: @membership.errors.full_messages.to_sentence
    end
  end

  def update
    @membership = @project.project_memberships.find(params[:id])
    new_rate = (params[:hourly_rate_dollars].to_f * 100).round

    if @membership.update(hourly_rate_cents: new_rate)
      redirect_to project_path(@project, tab: "members"), notice: "Rate updated."
    else
      redirect_to project_path(@project, tab: "members"), alert: @membership.errors.full_messages.to_sentence
    end
  end

  def destroy
    @membership = @project.project_memberships.find(params[:id])
    name = @membership.user.name
    @membership.destroy
    redirect_to project_path(@project, tab: "members"), notice: "#{name} removed from project.", status: :see_other
  end

  private

  def set_project
    @project = current_workspace.projects.find(params[:project_id])
  end
end
```

- [ ] **Step 3: Update ProjectsController**

In `app/controllers/projects_controller.rb`:

Update `show` action to load members:
```ruby
  def show
    @tab = params[:tab] || "settings"
    @tasks = @project.tasks.order(:name)
    @time_entries = @project.time_entries.completed.includes(:user, :task, :tags).order(started_at: :desc).limit(20)
    @total_seconds = @project.time_entries.completed.sum(:duration_seconds)
    @task_time_recap = @project.time_entries.completed
      .where.not(task_id: nil)
      .joins(:task)
      .group("tasks.id", "tasks.name", "tasks.status")
      .sum(:duration_seconds)
      .sort_by { |_, seconds| -seconds }

    if @tab == "members"
      @memberships = @project.project_memberships.eager_load(:user).order("users.name")
      @available_users = current_workspace.users
        .where.not(id: @project.project_memberships.select(:user_id))
        .order(:name)
    end
  end
```

Update `project_params` (line 77):
```ruby
  def project_params
    params.require(:project).permit(:name, :client_id, :color, :currency,
                                    :budget_type, :budget_cents, :budget_hours,
                                    :external_type, :external_reference)
  end
```

- [ ] **Step 4: Add currency field to project form**

In `app/views/projects/_form.html.erb`, after the color field (line 30), add:

```erb
  <div class="space-y-1">
    <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Currency</label>
    <%= f.select :currency, Project::CURRENCIES.map { |c| [c, c] },
        {}, class: "m3-text-field w-full" %>
  </div>
```

The billable checkbox and hourly rate field should already be removed from Task 6.

- [ ] **Step 5: Redesign project show page with tabs**

Rewrite `app/views/projects/show.html.erb` to include tabs:

```erb
<div class="space-y-5">
  <div class="flex justify-between items-center">
    <div class="flex items-center gap-3">
      <span class="block w-4 h-4 rounded-full" style="background-color: <%= @project.color %>"></span>
      <h1 class="text-2xl font-bold tracking-tight" style="color: var(--color-on-surface)"><%= @project.name %></h1>
    </div>
    <div class="flex gap-2">
      <%= link_to "Edit", edit_project_path(@project), class: "m3-btn m3-btn-outlined m3-btn-sm" %>
      <% if @project.archived? %>
        <%= button_to "Restore", unarchive_project_path(@project), method: :patch, class: "m3-btn m3-btn-text m3-btn-sm" %>
      <% else %>
        <%= button_to "Archive", archive_project_path(@project), method: :patch, class: "m3-btn m3-btn-text m3-btn-sm",
            data: { turbo_confirm: "Archive this project?" } %>
      <% end %>
    </div>
  </div>

  <%# Tabs %>
  <div class="flex gap-0 border-b" style="border-color: var(--color-outline-variant)">
    <%= link_to project_path(@project, tab: "settings"),
        class: "px-4 py-2.5 text-sm font-medium border-b-2 -mb-px #{@tab == 'settings' ? '' : 'border-transparent'}" ,
        style: @tab == "settings" ? "border-color: var(--color-primary); color: var(--color-primary)" : "color: var(--color-on-surface-variant)" do %>
      Settings
    <% end %>
    <%= link_to project_path(@project, tab: "members"),
        class: "px-4 py-2.5 text-sm font-medium border-b-2 -mb-px #{@tab == 'members' ? '' : 'border-transparent'}",
        style: @tab == "members" ? "border-color: var(--color-primary); color: var(--color-primary)" : "color: var(--color-on-surface-variant)" do %>
      Members (<%= @project.project_memberships.count %>)
    <% end %>
  </div>

  <% if @tab == "settings" %>
    <%# Settings tab content %>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <div class="m3-card-elevated p-5">
        <h3 class="text-sm font-semibold mb-3" style="color: var(--color-on-surface-variant)">Details</h3>
        <dl class="space-y-2 text-sm">
          <div class="flex justify-between"><dt style="color: var(--color-outline)">Client</dt><dd><%= @project.client&.name || "—" %></dd></div>
          <div class="flex justify-between"><dt style="color: var(--color-outline)">Currency</dt><dd><%= @project.currency %></dd></div>
          <div class="flex justify-between"><dt style="color: var(--color-outline)">Budget</dt><dd><%= @project.budget_type.titleize %></dd></div>
          <% if @project.money? %>
            <div class="flex justify-between"><dt style="color: var(--color-outline)">Budget Amount</dt><dd><%= number_to_currency(@project.budget_cents.to_f / 100) %></dd></div>
          <% elsif @project.hours? %>
            <div class="flex justify-between"><dt style="color: var(--color-outline)">Budget Hours</dt><dd><%= @project.budget_hours %></dd></div>
          <% end %>
          <div class="flex justify-between"><dt style="color: var(--color-outline)">Total Time</dt><dd><%= format_duration_hm(@total_seconds) %></dd></div>
        </dl>
      </div>

      <% if @project.money? || @project.hours? %>
        <div class="m3-card-elevated p-5">
          <h3 class="text-sm font-semibold mb-3" style="color: var(--color-on-surface-variant)">Budget Progress</h3>
          <div class="text-2xl font-bold" style="color: var(--color-primary)"><%= @project.budget_percentage %>%</div>
          <div class="w-full h-2 rounded-full mt-2" style="background: var(--color-surface-container-highest)">
            <div class="h-2 rounded-full" style="width: <%= [@project.budget_percentage, 100].min %>%; background: var(--color-primary)"></div>
          </div>
        </div>
      <% end %>
    </div>

    <% if @task_time_recap.any? %>
      <div class="m3-card-outlined overflow-hidden">
        <table class="m3-table">
          <thead><tr><th>Task</th><th>Status</th><th class="text-right">Time</th></tr></thead>
          <tbody>
            <% @task_time_recap.each do |(task_id, task_name, task_status), seconds| %>
              <tr>
                <td class="text-sm"><%= task_name %></td>
                <td><span class="text-xs px-2 py-0.5 rounded-full" style="background: var(--color-surface-container-highest); color: var(--color-on-surface-variant)"><%= task_status %></span></td>
                <td class="text-right text-sm mono-duration"><%= format_duration_hm(seconds) %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>

  <% else %>
    <%# Members tab content %>
    <div class="flex justify-between items-center mb-4">
      <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">Project Members</h2>
      <% if @available_users.any? %>
        <div class="relative" data-controller="dropdown">
          <button class="m3-btn m3-btn-filled" data-action="click->dropdown#toggle">Add Member</button>
          <div class="hidden absolute right-0 top-full mt-1 m3-menu z-50 w-72" data-dropdown-target="menu">
            <% @available_users.each do |user| %>
              <%= form_with url: project_project_memberships_path(@project), method: :post, class: "m3-menu-item flex justify-between items-center" do %>
                <input type="hidden" name="user_id" value="<%= user.id %>">
                <input type="hidden" name="hourly_rate_dollars" value="0">
                <div class="flex items-center gap-2">
                  <div class="m3-avatar m3-avatar-sm"><%= user.name.first(2).upcase %></div>
                  <div>
                    <div class="text-sm font-medium"><%= user.name %></div>
                    <div class="text-xs" style="color: var(--color-outline)"><%= user.email_address %></div>
                  </div>
                </div>
                <button type="submit" class="text-xs font-medium" style="color: var(--color-primary)">Add</button>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>

    <div class="m3-card-outlined overflow-hidden">
      <% @memberships.each do |membership| %>
        <div class="p-4 border-b" style="border-color: var(--color-outline-variant)" data-controller="rate-history">
          <div class="flex justify-between items-center">
            <div class="flex items-center gap-3">
              <div class="m3-avatar m3-avatar-sm"><%= membership.user.name.first(2).upcase %></div>
              <div>
                <div class="text-sm font-medium" style="color: var(--color-on-surface)"><%= membership.user.name %></div>
                <div class="text-xs" style="color: var(--color-outline)"><%= membership.user.email_address %></div>
              </div>
            </div>
            <div class="flex items-center gap-3">
              <%= form_with url: project_project_membership_path(@project, membership), method: :patch, class: "flex items-center gap-2" do %>
                <input type="number" name="hourly_rate_dollars" step="0.01" min="0"
                       value="<%= membership.hourly_rate_cents / 100.0 %>"
                       class="m3-text-field w-24 text-right text-sm"
                       data-action="change->this#submit">
                <span class="text-xs" style="color: var(--color-outline)"><%= @project.currency %>/hr</span>
                <button type="submit" class="m3-btn m3-btn-text m3-btn-sm">Save</button>
              <% end %>
              <button class="text-xs font-medium" style="color: var(--color-primary)" data-action="click->rate-history#toggle">History</button>
              <%= button_to "Remove", project_project_membership_path(@project, membership), method: :delete,
                  class: "text-xs font-medium", style: "color: var(--color-error)",
                  data: { turbo_confirm: "Remove #{membership.user.name} from this project?" } %>
            </div>
          </div>

          <%# Rate history (hidden by default) %>
          <div class="hidden mt-3 ml-11 p-3 rounded-lg" style="background: var(--color-surface-container)" data-rate-history-target="panel">
            <div class="text-xs font-medium mb-2" style="color: var(--color-outline)">Rate History</div>
            <% history = membership.rate_changes.order(changed_at: :desc) %>
            <% history.each_with_index do |rc, idx| %>
              <div class="flex justify-between text-xs py-1 border-b" style="border-color: var(--color-outline-variant)">
                <span style="color: <%= idx == 0 ? 'var(--color-on-surface)' : 'var(--color-outline)' %>">
                  <%= rc.hourly_rate_cents / 100.0 %> <%= @project.currency %>/hr
                </span>
                <span style="color: var(--color-outline)">
                  <%= rc.changed_at.strftime("%b %-d, %Y") %> —
                  <%= idx == 0 ? "Current" : history[idx - 1].changed_at.strftime("%b %-d, %Y") %>
                </span>
              </div>
            <% end %>
            <% if history.empty? %>
              <div class="text-xs" style="color: var(--color-outline)">No rate changes recorded.</div>
            <% end %>
          </div>
        </div>
      <% end %>

      <% if @memberships.empty? %>
        <div class="p-8 text-center text-sm" style="color: var(--color-outline)">No members assigned yet.</div>
      <% end %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Create Stimulus controllers for the UI interactions**

Create `app/javascript/controllers/rate_history_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel"]

  toggle() {
    this.panelTarget.classList.toggle("hidden")
  }
}
```

Create `app/javascript/controllers/dropdown_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  toggle() {
    this.menuTarget.classList.toggle("hidden")
  }

  close(event) {
    if (!this.element.contains(event.target)) {
      this.menuTarget.classList.add("hidden")
    }
  }

  connect() {
    this.boundClose = this.close.bind(this)
    document.addEventListener("click", this.boundClose)
  }

  disconnect() {
    document.removeEventListener("click", this.boundClose)
  }
}
```

Register both in the Stimulus manifest (if auto-loading isn't set up, otherwise they'll be auto-discovered).

- [ ] **Step 7: Run the app and manually test**

Run: `bin/rails server`

Verify:
- Project show page has Settings/Members tabs
- Members tab shows assigned users with rate inputs
- Add Member dropdown works
- Rate history expands inline
- Remove button works

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: add project Settings/Members tabs with rate management"
```

---

## Chunk 5: Team Page & Data Migration

### Task 11: Update Team page with expandable project assignments

**Files:**
- Modify: `app/controllers/workspace_members_controller.rb` — load project memberships
- Modify: `app/views/workspace_members/index.html.erb` — add expandable project rows

- [ ] **Step 1: Update WorkspaceMembersController index**

In `app/controllers/workspace_members_controller.rb`, update the `index` method:

```ruby
  def index
    @memberships = current_workspace.workspace_memberships
      .includes(user: { project_memberships: :project })
      .order("users.name")
  end
```

- [ ] **Step 2: Update team page view**

Rewrite `app/views/workspace_members/index.html.erb`:

```erb
<div class="space-y-5">
  <div class="flex justify-between items-center">
    <h1 class="text-2xl font-bold tracking-tight" style="color: var(--color-on-surface)">Team Members</h1>
    <%= link_to "Add Member", new_workspace_member_path, class: "m3-btn m3-btn-filled" %>
  </div>

  <div class="m3-card-outlined overflow-hidden">
    <% @memberships.each do |membership| %>
      <div class="border-b" style="border-color: var(--color-outline-variant)" data-controller="team-expand">
        <div class="flex justify-between items-center p-4">
          <div class="flex items-center gap-2.5">
            <div class="m3-avatar m3-avatar-sm"><%= membership.user.name.first(2).upcase %></div>
            <div>
              <span class="text-sm font-medium" style="color: var(--color-on-surface)"><%= membership.user.name %></span>
              <div class="text-xs" style="color: var(--color-outline)"><%= membership.user.email_address %></div>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <span class="text-[10px] font-semibold uppercase tracking-wider px-2.5 py-1 rounded-full"
                  style="<%= role_badge_style(membership.role) %>">
              <%= membership.role %>
            </span>
            <% project_count = membership.user.project_memberships.joins(:project).where(projects: { workspace_id: current_workspace.id }).count %>
            <span class="text-xs" style="color: var(--color-outline)"><%= project_count %> projects</span>
            <button class="text-lg" style="color: var(--color-outline); cursor: pointer" data-action="click->team-expand#toggle" data-team-expand-target="arrow">&#9662;</button>
            <% unless membership.user == current_user %>
              <div class="flex gap-1">
                <%= link_to "Edit", edit_workspace_member_path(membership), class: "m3-btn m3-btn-text m3-btn-sm" %>
                <%= button_to "Remove", workspace_member_path(membership), method: :delete,
                    class: "m3-btn m3-btn-text m3-btn-sm", style: "color: var(--color-error)",
                    data: { turbo_confirm: "Remove #{membership.user.name} from this workspace?" } %>
              </div>
            <% else %>
              <span class="text-xs px-2 py-1" style="color: var(--color-outline)">You</span>
            <% end %>
          </div>
        </div>

        <div class="hidden pb-4 px-4 ml-11" data-team-expand-target="panel">
          <div class="p-3 rounded-lg" style="background: var(--color-surface-container)">
            <div class="text-xs font-medium mb-2" style="color: var(--color-outline)">Assigned Projects</div>
            <% user_project_memberships = membership.user.project_memberships.joins(:project).where(projects: { workspace_id: current_workspace.id }).includes(:project) %>
            <% user_project_memberships.each do |pm| %>
              <div class="flex justify-between text-xs py-1.5 border-b" style="border-color: var(--color-outline-variant)">
                <div class="flex items-center gap-2">
                  <span class="block w-2 h-2 rounded-full" style="background-color: <%= pm.project.color %>"></span>
                  <%= link_to pm.project.name, project_path(pm.project, tab: "members"), class: "font-medium", style: "color: var(--color-on-surface)" %>
                </div>
                <span style="color: var(--color-on-surface-variant)"><%= pm.hourly_rate_cents / 100.0 %> <%= pm.project.currency %>/hr</span>
              </div>
            <% end %>
            <% if user_project_memberships.empty? %>
              <div class="text-xs py-1" style="color: var(--color-outline)">Not assigned to any projects.</div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
  </div>
</div>
```

- [ ] **Step 3: Create team-expand Stimulus controller**

```javascript
// app/javascript/controllers/team_expand_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "arrow"]

  toggle() {
    this.panelTarget.classList.toggle("hidden")
    this.arrowTarget.textContent = this.panelTarget.classList.contains("hidden") ? "▾" : "▴"
  }
}
```

- [ ] **Step 4: Run the app and manually test**

Run: `bin/rails server`

Verify:
- Team page shows all members with project counts
- Clicking arrow expands to show project assignments with rates
- Project links go to project members tab

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add expandable project assignments to team page"
```

---

### Task 12: Data migration — populate project memberships and currency

**Files:**
- Create: `db/migrate/TIMESTAMP_migrate_workspace_to_project_data.rb`

- [ ] **Step 1: Create data migration**

Run: `bin/rails generate migration MigrateWorkspaceToProjectData`

```ruby
class MigrateWorkspaceToProjectData < ActiveRecord::Migration[8.0]
  def up
    # Check for orphan time entries (no project)
    orphan_count = TimeEntry.where(project_id: nil).count
    if orphan_count > 0
      raise "Found #{orphan_count} time entries without a project. Assign them to a project before running this migration."
    end

    # Copy workspace currency to all projects
    execute <<-SQL
      UPDATE projects
      SET currency = (
        SELECT COALESCE(workspaces.default_currency, 'USD')
        FROM workspaces
        WHERE workspaces.id = projects.workspace_id
      )
    SQL

    # Set all time entries to billable before column removal
    execute "UPDATE time_entries SET billable = true WHERE billable = false OR billable IS NULL"

    # Create project_memberships for all user x project combinations
    execute <<-SQL
      INSERT INTO project_memberships (project_id, user_id, hourly_rate_cents, created_at, updated_at)
      SELECT p.id, wm.user_id, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM projects p
      JOIN workspace_memberships wm ON wm.workspace_id = p.workspace_id
      WHERE NOT EXISTS (
        SELECT 1 FROM project_memberships pm
        WHERE pm.project_id = p.id AND pm.user_id = wm.user_id
      )
    SQL
  end

  def down
    # No rollback for data migration — would need manual intervention
    raise ActiveRecord::IrreversibleMigration
  end
end
```

- [ ] **Step 2: Run migration**

Run: `bin/rails db:migrate`

- [ ] **Step 3: Verify in console**

Run: `bin/rails console`

```ruby
puts ProjectMembership.count
puts Project.where(currency: nil).count  # Should be 0
```

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "data: migrate workspace currency to projects and create project memberships"
```

---

### Task 13: Remove deprecated columns

**Files:**
- Create: `db/migrate/TIMESTAMP_remove_deprecated_columns.rb`

- [ ] **Step 1: Generate migration**

Run: `bin/rails generate migration RemoveDeprecatedColumns`

```ruby
class RemoveDeprecatedColumns < ActiveRecord::Migration[8.0]
  def change
    # Add NOT NULL constraint on time_entries.project_id (data migration ensured no orphans)
    change_column_null :time_entries, :project_id, false

    remove_column :workspaces, :default_currency, :string
    remove_column :workspaces, :default_hourly_rate_cents, :integer
    remove_column :workspaces, :week_start, :integer
    remove_column :workspaces, :time_format, :integer
    remove_column :projects, :hourly_rate_cents, :integer
    remove_column :projects, :billable, :boolean
    remove_column :tasks, :hourly_rate_cents, :integer
    remove_column :tasks, :billable, :boolean
    remove_column :users, :default_hourly_rate_cents, :integer
    remove_column :time_entries, :billable, :boolean
  end
end
```

- [ ] **Step 2: Run migration**

Run: `bin/rails db:migrate`

- [ ] **Step 3: Update fixtures**

In `test/fixtures/workspaces.yml`, remove `default_currency` and `default_hourly_rate_cents`:

```yaml
one:
  name: Test Workspace

two:
  name: Other Workspace
```

In `test/fixtures/projects.yml`, add currency:

```yaml
jira_project:
  name: Elvium
  workspace: one
  color: "#3B82F6"
  currency: USD
  external_type: jira
  external_reference: ELV

plain_project:
  name: Internal
  workspace: one
  color: "#EF4444"
  currency: USD
```

- [ ] **Step 4: Run all tests**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: remove deprecated columns from workspaces, projects, tasks, users, time_entries"
```

---

### Task 14: Final cleanup and edge cases

**Files:**
- Modify: `app/views/projects/index.html.erb` — remove billable column if present
- Modify: `app/controllers/tasks_controller.rb` — remove billable from task params if present
- Verify: All views referencing removed columns are cleaned up

- [ ] **Step 1: Search for any remaining references to removed columns**

Run: `grep -rn "default_hourly_rate\|default_currency\|week_start\|time_format\|\.billable" app/ --include="*.rb" --include="*.erb" | grep -v "project_membership\|currency"`

Fix any remaining references.

- [ ] **Step 2: Update tasks controller if needed**

In `app/controllers/tasks_controller.rb`, remove `:billable` and `:hourly_rate_cents` from permitted params if present.

- [ ] **Step 3: Run full test suite**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 4: Manual smoke test**

Run: `bin/rails server`

Verify:
1. Admin: sidebar shows Manage + Reports sections
2. Employee: sidebar shows only Time Entries, Timesheet, Tags
3. Admin: project show page has Settings/Members tabs
4. Admin: can add/remove members, set rates, see rate history
5. Admin: team page shows expandable project assignments
6. Employee: project dropdown in timer only shows assigned projects
7. Employee: cannot access /projects, /reports/summary directly (redirects)
8. Creating/stopping a time entry locks the rate from project membership
9. No "billable" checkboxes anywhere
10. Workspace settings page is gone

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: final cleanup of removed column references"
```
