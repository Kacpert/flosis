# Project Report Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An admin-only `/reports/project` page with a project dropdown + month picker showing three stats for the selected project/month: hours worked (per-user + total), tasks moved to "Customer Acceptance", and bugs worked on.

**Architecture:** A `ProjectMonthlyReport` PORO computes the four figures from time entries (hours) and Jira tasks (counts, scoped by a new real `tasks.jira_updated_at` populated during Jira sync). A thin admin-only `Reports::ProjectReportsController#show` renders them; a sidebar link in the Reports group is the entry point.

**Tech Stack:** Rails 8.1.2, Minitest, Tailwind, Net::HTTP (Jira client), Solid Queue (sync job).

## Global Constraints

- Admin/owner only for the report page (reuse `require_admin!`), under `namespace :reports`.
- App time zone is Warsaw; month range = `month.beginning_of_month..month.end_of_month`.
- Real production Jira values: status string is exactly `"Customer Acceptance"`, issue_type is exactly `"Bug"`.
- Tasks store `labels` as a JSON string; `jira_synced` scope = `where(external_type: "jira")`.
- Follow existing reports patterns: singular `resource` under `namespace :reports`, `WorkspaceScoped` + `require_admin!`, `m3-*` view classes.

---

### Task 1: Add `tasks.jira_updated_at` and populate it from Jira

**Files:**
- Create: `db/migrate/20260619000001_add_jira_updated_at_to_tasks.rb`
- Modify: `app/services/jira_client.rb` (request `"updated"` field ~line 42; add `updated:` to the parsed issue hash ~line 232)
- Modify: `app/services/jira_sync_service.rb` (set `jira_updated_at:` in `assign_attributes`, ~line 126)
- Test: `test/services/jira_client_test.rb` or a focused new test (see below)

**Interfaces:**
- Produces: `Task#jira_updated_at` (datetime); `JiraClient#parse_issue` returns hash key `:updated` (a time string or nil); `JiraSyncService` persists it.

- [ ] **Step 1: Write the failing test**

Create `test/services/jira_updated_at_sync_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class JiraUpdatedAtSyncTest < ActiveSupport::TestCase
  test "parse_issue extracts the Jira updated timestamp" do
    client = JiraClient.allocate
    client.instance_variable_set(:@domain, "ex.atlassian.net")
    issue = {
      "key" => "DEV-1", "fields" => {
        "summary" => "x", "status" => { "name" => "To Do", "statusCategory" => { "key" => "new" } },
        "updated" => "2026-06-10T12:00:00.000+0200", "issuetype" => { "name" => "Bug" }
      }
    }
    parsed = client.send(:parse_issue, issue)
    assert_equal "2026-06-10T12:00:00.000+0200", parsed[:updated]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/jira_updated_at_sync_test.rb`
Expected: FAIL — `parsed[:updated]` is nil (key not present yet).

- [ ] **Step 3: Add the migration and migrate**

Create `db/migrate/20260619000001_add_jira_updated_at_to_tasks.rb`:

```ruby
class AddJiraUpdatedAtToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :jira_updated_at, :datetime
    add_index :tasks, [ :project_id, :jira_updated_at ]
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: column + index created.

- [ ] **Step 4: Request and parse the `updated` field in JiraClient**

In `app/services/jira_client.rb`, the search `fields:` array (around line 42) currently is:

```ruby
        fields: ["summary", "status", "assignee", "description", "priority", "issuetype", "labels", "reporter", "sprint", "timeoriginalestimate", "attachment"],
```

Add `"updated"`:

```ruby
        fields: ["summary", "status", "assignee", "description", "priority", "issuetype", "labels", "reporter", "sprint", "timeoriginalestimate", "attachment", "updated"],
```

In the `parse_issue` return hash (around line 232, after `time_estimate_seconds:`), add:

```ruby
      updated: fields["updated"],
```

- [ ] **Step 5: Persist it in the sync**

In `app/services/jira_sync_service.rb`, inside the `task.assign_attributes(` block in `sync_issue` (alongside `issue_type:` / `labels:`), add:

```ruby
      jira_updated_at: issue[:updated],
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/services/jira_updated_at_sync_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260619000001_add_jira_updated_at_to_tasks.rb db/schema.rb app/services/jira_client.rb app/services/jira_sync_service.rb test/services/jira_updated_at_sync_test.rb
git commit -m "feat: store Jira issue updated timestamp on tasks"
```

---

### Task 2: `ProjectMonthlyReport` service

**Files:**
- Create: `app/services/project_monthly_report.rb`
- Test: `test/services/project_monthly_report_test.rb`

**Interfaces:**
- Consumes: `Task#jira_updated_at`, `Task#jira_status_name`, `Task#issue_type` (from Task 1); `Project#time_entries`, `TimeEntry.completed`, `TimeEntry.in_range`.
- Produces: `ProjectMonthlyReport.new(project:, month:)` with:
  - `total_seconds` → Integer
  - `per_user_hours` → `[{ user: User, seconds: Integer, percent: Float }]`, sorted desc by seconds
  - `customer_acceptance_count` → Integer
  - `bugs_count` → Integer

- [ ] **Step 1: Write the failing test**

Create `test/services/project_monthly_report_test.rb`:

```ruby
require "test_helper"

class ProjectMonthlyReportTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @month = Date.new(2026, 6, 1)
    @from = @month.beginning_of_month
  end

  def entry(user, hours, at: @from + 9.hours)
    @project.time_entries.create!(
      workspace: @project.workspace, user: user,
      started_at: at, stopped_at: at + hours.hours
    )
  end

  def report
    ProjectMonthlyReport.new(project: @project, month: @month)
  end

  test "total_seconds sums completed entries in the month for the project" do
    entry(users(:one), 2)
    entry(users(:two), 1)
    entry(users(:one), 5, at: @month.prev_month.beginning_of_month + 9.hours) # other month, excluded
    assert_equal 3 * 3600, report.total_seconds
  end

  test "per_user_hours groups by user with percentages, sorted desc" do
    entry(users(:one), 3)
    entry(users(:two), 1)
    rows = report.per_user_hours
    assert_equal users(:one), rows.first[:user]
    assert_equal 3 * 3600, rows.first[:seconds]
    assert_in_delta 75.0, rows.first[:percent], 0.1
  end

  test "customer_acceptance_count counts jira tasks in that status updated in month" do
    @project.tasks.create!(name: "CA in month", external_type: "jira", external_reference: "CA-1",
      jira_status_name: "Customer Acceptance", jira_updated_at: @from + 2.days)
    @project.tasks.create!(name: "CA other month", external_type: "jira", external_reference: "CA-2",
      jira_status_name: "Customer Acceptance", jira_updated_at: @month.prev_month)
    @project.tasks.create!(name: "Other status", external_type: "jira", external_reference: "CA-3",
      jira_status_name: "In Progress", jira_updated_at: @from + 2.days)
    assert_equal 1, report.customer_acceptance_count
  end

  test "bugs_count counts Bug issue_type updated in month" do
    @project.tasks.create!(name: "Bug in month", external_type: "jira", external_reference: "B-1",
      issue_type: "Bug", jira_updated_at: @from + 1.day)
    @project.tasks.create!(name: "Story", external_type: "jira", external_reference: "B-2",
      issue_type: "Story", jira_updated_at: @from + 1.day)
    @project.tasks.create!(name: "Bug other month", external_type: "jira", external_reference: "B-3",
      issue_type: "Bug", jira_updated_at: @month.prev_month)
    assert_equal 1, report.bugs_count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/project_monthly_report_test.rb`
Expected: FAIL — `uninitialized constant ProjectMonthlyReport`.

- [ ] **Step 3: Implement the service**

Create `app/services/project_monthly_report.rb`:

```ruby
# Computes the monthly report figures for one project. Pure read model.
class ProjectMonthlyReport
  CUSTOMER_ACCEPTANCE_STATUS = "Customer Acceptance".freeze
  BUG_ISSUE_TYPE = "Bug".freeze

  def initialize(project:, month:)
    @project = project
    @from = month.beginning_of_month.beginning_of_day
    @to = month.end_of_month.end_of_day
  end

  def total_seconds
    completed_entries.sum(:duration_seconds)
  end

  def per_user_hours
    total = total_seconds.to_f
    completed_entries
      .joins(:user)
      .group("users.id")
      .sum(:duration_seconds)
      .map { |user_id, seconds| { user: User.find(user_id), seconds: seconds,
                                  percent: total.zero? ? 0.0 : (seconds / total * 100).round(1) } }
      .sort_by { |row| -row[:seconds] }
  end

  def customer_acceptance_count
    jira_tasks.where(jira_status_name: CUSTOMER_ACCEPTANCE_STATUS)
              .where(jira_updated_at: @from..@to).count
  end

  def bugs_count
    jira_tasks.where(issue_type: BUG_ISSUE_TYPE)
              .where(jira_updated_at: @from..@to).count
  end

  private

  def completed_entries
    @project.time_entries.completed.in_range(@from, @to)
  end

  def jira_tasks
    @project.tasks.jira_synced
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/project_monthly_report_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/project_monthly_report.rb test/services/project_monthly_report_test.rb
git commit -m "feat: ProjectMonthlyReport computes hours + Jira stats"
```

---

### Task 3: Controller, route, and view

**Files:**
- Modify: `config/routes.rb` (add `resource :project_report, only: [:show]` in `namespace :reports`)
- Create: `app/controllers/reports/project_reports_controller.rb`
- Create: `app/views/reports/project_reports/show.html.erb`
- Test: `test/controllers/reports/project_reports_controller_test.rb`

**Interfaces:**
- Consumes: `ProjectMonthlyReport` (Task 2); `current_workspace.projects.active`.
- Produces: route helper `reports_project_report_path`.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/reports/project_reports_controller_test.rb`:

```ruby
require "test_helper"

class Reports::ProjectReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    @month = "2026-06"
    @from = Date.new(2026, 6, 1).beginning_of_month
    @project.time_entries.create!(workspace: @project.workspace, user: users(:one),
      started_at: @from + 9.hours, stopped_at: @from + 12.hours) # 3h
    @project.tasks.create!(name: "CA", external_type: "jira", external_reference: "CA-9",
      jira_status_name: "Customer Acceptance", jira_updated_at: @from + 1.day)
    @project.tasks.create!(name: "Bugz", external_type: "jira", external_reference: "B-9",
      issue_type: "Bug", jira_updated_at: @from + 1.day)
  end

  test "admin sees the report with the three figures" do
    sign_in_as(users(:one))
    get reports_project_report_path(project_id: @project.id, month: @month)
    assert_response :success
    assert_match "3h 0m", response.body          # hours (format_duration_hm)
    assert_match "Customer Acceptance", response.body
    assert_match users(:one).name, response.body # per-user row
  end

  test "employee is blocked" do
    sign_in_as(users(:two))
    get reports_project_report_path(project_id: @project.id, month: @month)
    assert_redirected_to root_path
  end

  test "defaults to current month and first project when params omitted" do
    sign_in_as(users(:one))
    get reports_project_report_path
    assert_response :success
  end

  test "a project from another workspace is not accessible" do
    sign_in_as(users(:one))
    get reports_project_report_path(project_id: projects(:other_jira_project).id, month: @month)
    # falls back to a project in the current workspace rather than leaking another workspace's
    assert_response :success
    assert_not_includes response.body, projects(:other_jira_project).name
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/reports/project_reports_controller_test.rb`
Expected: FAIL — no route `reports_project_report_path`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside `namespace :reports do` (after the `resource :weekly` block), add:

```ruby
    resource :project_report, only: [ :show ]
```

- [ ] **Step 4: Create the controller**

Create `app/controllers/reports/project_reports_controller.rb`:

```ruby
module Reports
  class ProjectReportsController < ApplicationController
    include WorkspaceScoped
    before_action :require_admin!

    def show
      @projects = current_workspace.projects.active.order(:name)
      @project = @projects.find_by(id: params[:project_id]) || @projects.first
      @month = parse_month(params[:month])

      if @project
        @report = ProjectMonthlyReport.new(project: @project, month: @month)
      end
    end

    private

    def parse_month(value)
      Date.strptime(value, "%Y-%m").beginning_of_month
    rescue ArgumentError, TypeError
      Date.current.beginning_of_month
    end
  end
end
```

- [ ] **Step 5: Create the view**

Create `app/views/reports/project_reports/show.html.erb`:

```erb
<div class="max-w-4xl mx-auto space-y-6">
  <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)">Project Report</h1>

  <%= form_with url: reports_project_report_path, method: :get, class: "filter-panel flex items-end gap-3" do |f| %>
    <div>
      <label class="block text-xs mb-1" style="color: var(--color-on-surface-variant)">Project</label>
      <%= f.select :project_id, @projects.map { |p| [ p.name, p.id ] },
            { selected: @project&.id }, class: "m3-text-field" %>
    </div>
    <div>
      <label class="block text-xs mb-1" style="color: var(--color-on-surface-variant)">Month</label>
      <%= f.month_field :month, value: @month.strftime("%Y-%m"), class: "m3-text-field" %>
    </div>
    <%= f.submit "Apply", class: "m3-btn m3-btn-filled m3-btn-sm" %>
  <% end %>

  <% if @report %>
    <div class="flex gap-3">
      <div class="stat-card flex-1">
        <div class="stat-label">Hours worked</div>
        <div class="stat-number"><%= format_duration_hm(@report.total_seconds) %></div>
      </div>
      <div class="stat-card flex-1">
        <div class="stat-label">→ Customer Acceptance</div>
        <div class="stat-number"><%= @report.customer_acceptance_count %></div>
      </div>
      <div class="stat-card flex-1">
        <div class="stat-label">Bugs worked on</div>
        <div class="stat-number"><%= @report.bugs_count %></div>
      </div>
    </div>

    <div class="m3-card-outlined overflow-hidden">
      <div class="px-4 py-3 border-b flex items-center justify-between" style="border-color: var(--color-outline-variant)">
        <h2 class="text-base font-bold" style="color: var(--color-on-surface)">Hours by person</h2>
        <span class="font-mono font-bold text-sm" style="color: var(--color-on-surface)"><%= format_duration_hm(@report.total_seconds) %></span>
      </div>
      <% if @report.per_user_hours.any? %>
        <% @report.per_user_hours.each do |row| %>
          <div class="flex items-center justify-between px-4 py-3 border-b" style="border-color: var(--color-outline-variant)">
            <span class="text-sm" style="color: var(--color-on-surface)"><%= row[:user].name %></span>
            <span class="flex items-center gap-3">
              <span class="text-sm" style="color: var(--color-on-surface-variant)"><%= row[:percent] %>%</span>
              <span class="font-mono font-bold text-sm" style="color: var(--color-on-surface)"><%= format_duration_hm(row[:seconds]) %></span>
            </span>
          </div>
        <% end %>
      <% else %>
        <div class="p-4 text-sm" style="color: var(--color-outline)">No time logged this month.</div>
      <% end %>
    </div>

    <p class="text-xs" style="color: var(--color-outline)">Jira stats reflect the latest synced data.</p>
  <% else %>
    <div class="m3-card-outlined p-6 text-center">
      <p class="text-sm" style="color: var(--color-outline)">No projects to report on.</p>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/controllers/reports/project_reports_controller_test.rb`
Expected: PASS (4 tests). (`format_duration_hm(3*3600)` renders `"3h 0m"`, which the test asserts.)

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/reports/project_reports_controller.rb app/views/reports/project_reports/show.html.erb test/controllers/reports/project_reports_controller_test.rb
git commit -m "feat: project monthly report page (controller, route, view)"
```

---

### Task 4: Sidebar link + deploy

**Files:**
- Modify: `app/views/layouts/application.html.erb` (Reports group, ~line 131–146)
- Test: `test/controllers/reports/project_reports_controller_test.rb` (append sidebar assertions)

**Interfaces:**
- Consumes: `reports_project_report_path` (Task 3); `current_user.admin_or_owner?`.

- [ ] **Step 1: Write the failing sidebar tests**

Append to `test/controllers/reports/project_reports_controller_test.rb` (inside the class):

```ruby
  test "sidebar shows the Project Report link for an admin" do
    sign_in_as(users(:one))
    get reports_summary_path
    assert_select "a[href=?]", reports_project_report_path
  end

  test "sidebar hides the Project Report link for an employee" do
    sign_in_as(users(:two))
    get root_path
    assert_select "a[href=?]", reports_project_report_path, count: 0
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/reports/project_reports_controller_test.rb -n "/sidebar/"`
Expected: the admin test FAILS (link not present yet); employee passes vacuously.

- [ ] **Step 3: Add the sidebar link**

In `app/views/layouts/application.html.erb`, the Reports group currently has Summary/Detailed/Weekly links (around lines 134–146). After the Weekly link's `<% end %>` and before the group closes, add (gated on admin/owner, matching how other admin items are gated in this file):

```erb
              <% if current_user.admin_or_owner?(current_workspace) %>
                <%= link_to reports_project_report_path, class: "m3-nav-item #{request.path == reports_project_report_path ? 'active' : ''}" do %>
                  <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z" /></svg>
                  <span>Project Report</span>
                <% end %>
              <% end %>
```

- [ ] **Step 4: Run tests + build CSS**

Run: `bin/rails test test/controllers/reports/project_reports_controller_test.rb`
Expected: PASS (all, incl. sidebar).

Run: `bin/rails tailwindcss:build`
Expected: builds without error.

- [ ] **Step 5: Commit**

```bash
git add app/views/layouts/application.html.erb test/controllers/reports/project_reports_controller_test.rb
git commit -m "feat: Project Report sidebar link (admin-only)"
```

- [ ] **Step 6: Regression + deploy**

Run: `bin/rails test test/services/project_monthly_report_test.rb test/services/jira_updated_at_sync_test.rb test/controllers/reports/project_reports_controller_test.rb`
Expected: all PASS.

Run: `bin/rails test test/controllers test/models test/services`
Expected: no NEW failures beyond the known pre-existing ones (holiday overlap, claude_cli `--add-dir` ×3, jira_sync `fetch_all_comments`).

```bash
git push origin production
cap production deploy
```

Expected: deploy exits 0; migration runs; full puma restart.

- [ ] **Step 7: Verify on production**

- Open the sidebar → "Project Report" (admin). Pick a project (e.g. Elvium) and the current month.
- Confirm Hours worked (with per-user rows + total), Customer Acceptance count, Bugs count render.
- Note: stats 2 & 3 fill in as the Jira sync runs (it populates `jira_updated_at`); a freshly-migrated DB shows them once tasks re-sync. Optionally trigger `JiraSyncJob.perform_now` on the server, then re-check.

---

## Notes for the implementer

- `jira_updated_at` is nil for all tasks until the next Jira sync after Task 1 deploys; counts for #2/#3 grow as tasks re-sync. This is expected (documented in the spec) and surfaced via the "reflects latest synced data" note.
- The report is read-only; no writes, no export (out of scope).
