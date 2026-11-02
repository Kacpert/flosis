# Jira Integration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync Jira issues as local tasks and provide a fuzzy-searchable dropdown in the timer bar for selecting them.

**Architecture:** A `JiraClient` service wraps the Jira Cloud REST API. A `JiraSyncService` syncs issues into local Task records. A Solid Queue recurring job keeps them fresh every 15 minutes. A new Stimulus controller provides a fuzzy-search dropdown on the description field when a Jira-connected project is selected.

**Tech Stack:** Rails 8.1, Stimulus, Solid Queue, Jira Cloud REST API v3, Net::HTTP, dotenv

**Spec:** `docs/superpowers/specs/2026-03-15-jira-integration-design.md`

---

## Chunk 1: Foundation (env, migration, model changes, fixtures)

### Task 1: Environment setup — dotenv and .env files

**Files:**
- Modify: `Gemfile`
- Create: `.env.example`
- Modify: `.gitignore`

- [ ] **Step 1: Add dotenv-rails to Gemfile**

`dotenv` is already a transitive dependency, but we need `dotenv-rails` explicitly to auto-load `.env` in development/test. Add to the Gemfile, before `gem "rails"`:

```ruby
gem "dotenv-rails", groups: [:development, :test]
```

- [ ] **Step 2: Bundle install**

Run: `bundle install`

- [ ] **Step 3: Create .env.example**

```
JIRA_DOMAIN=yourcompany.atlassian.net
JIRA_EMAIL=you@example.com
JIRA_API_TOKEN=your_api_token_here
```

- [ ] **Step 4: Create .env from .env.example**

Copy `.env.example` to `.env` and fill in the real Jira credentials. Do NOT put real credentials in any tracked file.

- [ ] **Step 5: Add .env to .gitignore**

Append to `.gitignore`:

```
.env
```

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock .env.example .gitignore
git commit -m "feat: add dotenv-rails and Jira env configuration"
```

---

### Task 2: Fixtures — create missing fixtures for test suite

Since `fixtures :all` is used globally, all fixtures must exist before running any tests. Create these now before the migration.

**Files:**
- Modify: `test/fixtures/users.yml`
- Create: `test/fixtures/workspaces.yml`
- Create: `test/fixtures/workspace_memberships.yml`
- Create: `test/fixtures/projects.yml`
- Create: `test/fixtures/tasks.yml`

- [ ] **Step 1: Update users fixture to add required `name` field**

Update `test/fixtures/users.yml`:

```yaml
<% password_digest = BCrypt::Password.create("password") %>

one:
  name: Kacper
  email_address: one@example.com
  password_digest: <%= password_digest %>

two:
  name: Other User
  email_address: two@example.com
  password_digest: <%= password_digest %>
```

- [ ] **Step 2: Create workspaces fixture**

Create `test/fixtures/workspaces.yml`:

```yaml
one:
  name: Test Workspace
  default_currency: USD
  default_hourly_rate_cents: 5000

two:
  name: Other Workspace
  default_currency: USD
```

- [ ] **Step 3: Create workspace_memberships fixture**

Create `test/fixtures/workspace_memberships.yml`:

```yaml
one_owner:
  user: one
  workspace: one
  role: 2

two_employee:
  user: two
  workspace: one
  role: 0
```

- [ ] **Step 4: Create projects fixture**

Create `test/fixtures/projects.yml`:

```yaml
jira_project:
  name: Elvium
  workspace: one
  color: "#3B82F6"
  external_type: jira
  external_reference: ELV

plain_project:
  name: Internal
  workspace: one
  color: "#EF4444"
```

- [ ] **Step 5: Create tasks fixture**

Create `test/fixtures/tasks.yml`:

```yaml
jira_task:
  name: "ELV-1 Existing task"
  project: jira_project
  external_type: jira
  external_reference: ELV-1
  external_url: https://elvium.atlassian.net/browse/ELV-1
  assignee_email: one@example.com

local_task:
  name: Daily standup
  project: jira_project
```

- [ ] **Step 6: Run existing tests to make sure fixtures don't break anything**

Run: `bin/rails test`
Expected: All existing tests still pass

- [ ] **Step 7: Commit**

```bash
git add test/fixtures/
git commit -m "feat: add missing test fixtures for workspaces, projects, tasks"
```

---

### Task 3: Migration — add assignee_email and jira_status_name to tasks

**Files:**
- Create: `db/migrate/TIMESTAMP_add_jira_fields_to_tasks.rb`

- [ ] **Step 1: Generate migration**

Run: `bin/rails generate migration AddJiraFieldsToTasks assignee_email:string jira_status_name:string`

- [ ] **Step 2: Add composite index for sync lookups**

Edit the generated migration to add an index:

```ruby
class AddJiraFieldsToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :assignee_email, :string
    add_column :tasks, :jira_status_name, :string
    add_index :tasks, [:project_id, :external_type, :external_reference], unique: true,
              name: "index_tasks_on_project_external_ref",
              where: "external_type IS NOT NULL"
  end
end
```

- [ ] **Step 3: Run migration**

Run: `bin/rails db:migrate`

- [ ] **Step 4: Verify schema.rb**

Check that `db/schema.rb` now has `t.string "assignee_email"` and `t.string "jira_status_name"` in the `tasks` table, plus the new index.

- [ ] **Step 5: Update tasks fixture with jira_status_name**

In `test/fixtures/tasks.yml`, update `jira_task`:

```yaml
jira_task:
  name: "ELV-1 Existing task"
  project: jira_project
  external_type: jira
  external_reference: ELV-1
  external_url: https://elvium.atlassian.net/browse/ELV-1
  assignee_email: one@example.com
  jira_status_name: In Progress
```

- [ ] **Step 6: Commit**

```bash
git add db/migrate/*_add_jira_fields_to_tasks.rb db/schema.rb test/fixtures/tasks.yml
git commit -m "feat: add assignee_email and jira_status_name columns to tasks"
```

---

### Task 4: Model changes — Project and Task helpers

**Files:**
- Modify: `app/models/project.rb`
- Modify: `app/models/task.rb`

- [ ] **Step 1: Add jira_connected? to Project model**

In `app/models/project.rb`, add after the `scope :archived` line:

```ruby
def jira_connected?
  external_type == "jira"
end
```

- [ ] **Step 2: Add Jira scopes to Task model**

In `app/models/task.rb`, add after the `enum :status` line:

```ruby
scope :jira_synced, -> { where(external_type: "jira") }
scope :local_only, -> { where(external_type: [nil, ""]) }
```

- [ ] **Step 3: Commit**

```bash
git add app/models/project.rb app/models/task.rb
git commit -m "feat: add jira_connected? helper and jira task scopes"
```

---

## Chunk 2: Jira client and sync service

### Task 5: JiraClient service

**Files:**
- Create: `app/services/jira_client.rb`
- Create: `test/services/jira_client_test.rb`

- [ ] **Step 1: Add webmock to Gemfile**

Add to the `:test` group in Gemfile:

```ruby
gem "webmock"
```

Run: `bundle install`

- [ ] **Step 2: Write the failing test**

Create `test/services/jira_client_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class JiraClientTest < ActiveSupport::TestCase
  setup do
    @client = JiraClient.new(
      domain: "test.atlassian.net",
      email: "test@example.com",
      api_token: "test-token"
    )
    @base_url = "https://test.atlassian.net/rest/api/3"
  end

  test "fetch_projects returns list of projects" do
    stub_request(:get, "#{@base_url}/project/search")
      .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64('test@example.com:test-token')}" })
      .to_return(
        status: 200,
        body: {
          values: [
            { key: "ELV", name: "Elvium", id: "10001" },
            { key: "GOLD", name: "Gold App", id: "10002" }
          ],
          isLast: true
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    projects = @client.fetch_projects

    assert_equal 2, projects.length
    assert_equal "ELV", projects.first[:key]
    assert_equal "Elvium", projects.first[:name]
  end

  test "fetch_projects returns empty array on failure" do
    stub_request(:get, "#{@base_url}/project/search")
      .to_return(status: 401, body: "Unauthorized")

    projects = @client.fetch_projects

    assert_equal [], projects
  end

  test "fetch_issues returns issues with status category" do
    stub_request(:get, "#{@base_url}/search")
      .with(query: hash_including({ "jql" => "project = ELV AND statusCategory != Done ORDER BY status ASC, updated DESC" }))
      .to_return(
        status: 200,
        body: {
          issues: [
            {
              key: "ELV-42",
              fields: {
                summary: "Fix login page",
                status: {
                  name: "In Progress",
                  statusCategory: { key: "indeterminate", name: "In Progress" }
                },
                assignee: { emailAddress: "kacper@example.com" }
              }
            }
          ],
          total: 1,
          startAt: 0,
          maxResults: 100
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    issues = @client.fetch_issues("ELV")

    assert_equal 1, issues.length
    issue = issues.first
    assert_equal "ELV-42", issue[:key]
    assert_equal "Fix login page", issue[:summary]
    assert_equal "indeterminate", issue[:status_category]
    assert_equal "In Progress", issue[:status_name]
    assert_equal "kacper@example.com", issue[:assignee_email]
    assert_equal "https://test.atlassian.net/browse/ELV-42", issue[:url]
  end

  test "fetch_issues handles pagination" do
    stub_request(:get, "#{@base_url}/search")
      .with(query: hash_including({ "startAt" => "0" }))
      .to_return(
        status: 200,
        body: {
          issues: Array.new(100) { |i| { key: "ELV-#{i}", fields: { summary: "Issue #{i}", status: { name: "To Do", statusCategory: { key: "new" } }, assignee: nil } } },
          total: 150,
          startAt: 0,
          maxResults: 100
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:get, "#{@base_url}/search")
      .with(query: hash_including({ "startAt" => "100" }))
      .to_return(
        status: 200,
        body: {
          issues: Array.new(50) { |i| { key: "ELV-#{100 + i}", fields: { summary: "Issue #{100 + i}", status: { name: "To Do", statusCategory: { key: "new" } }, assignee: nil } } },
          total: 150,
          startAt: 100,
          maxResults: 100
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    issues = @client.fetch_issues("ELV")

    assert_equal 150, issues.length
  end

  test "fetch_issues returns empty array on timeout" do
    stub_request(:get, "#{@base_url}/search")
      .to_timeout

    issues = @client.fetch_issues("ELV")

    assert_equal [], issues
  end

  test "fetch_issues validates project key format" do
    issues = @client.fetch_issues("'; DROP TABLE --")

    assert_equal [], issues
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/services/jira_client_test.rb`
Expected: FAIL — `NameError: uninitialized constant JiraClient`

- [ ] **Step 4: Implement JiraClient**

Create `app/services/jira_client.rb`:

```ruby
class JiraClient
  TIMEOUT = 10
  PROJECT_KEY_FORMAT = /\A[A-Z][A-Z0-9_]+\z/

  def initialize(domain: ENV["JIRA_DOMAIN"], email: ENV["JIRA_EMAIL"], api_token: ENV["JIRA_API_TOKEN"])
    @domain = domain
    @email = email
    @api_token = api_token
  end

  def fetch_projects
    results = []
    start_at = 0

    loop do
      data = get("/rest/api/3/project/search", startAt: start_at, maxResults: 50)
      return [] unless data

      values = data["values"] || []
      results.concat(values.map { |p| { key: p["key"], name: p["name"], id: p["id"] } })

      break if data["isLast"] != false
      start_at += values.length
    end

    results
  end

  def fetch_issues(project_key)
    return [] unless project_key.match?(PROJECT_KEY_FORMAT)

    results = []
    start_at = 0

    loop do
      data = get("/rest/api/3/search",
        jql: "project = #{project_key} AND statusCategory != Done ORDER BY status ASC, updated DESC",
        fields: "summary,status,assignee",
        startAt: start_at,
        maxResults: 100
      )
      return [] unless data

      issues = data["issues"] || []
      results.concat(issues.map { |i| parse_issue(i) })

      break if start_at + issues.length >= (data["total"] || 0)
      start_at += issues.length
    end

    results
  end

  private

  def parse_issue(issue)
    fields = issue["fields"] || {}
    status = fields.dig("status", "statusCategory") || {}

    {
      key: issue["key"],
      summary: fields["summary"],
      status_category: status["key"],
      status_name: fields.dig("status", "name"),
      assignee_email: fields.dig("assignee", "emailAddress"),
      url: "https://#{@domain}/browse/#{issue['key']}"
    }
  end

  def get(path, params = {})
    uri = URI("https://#{@domain}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{@email}:#{@api_token}")}"
    request["Accept"] = "application/json"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      Rails.logger.warn("[JiraClient] API error: #{response.code} #{response.message} for #{path}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.warn("[JiraClient] Connection error: #{e.message}")
    nil
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/services/jira_client_test.rb`
Expected: All 6 tests PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/jira_client.rb test/services/jira_client_test.rb Gemfile Gemfile.lock
git commit -m "feat: add JiraClient service for Jira Cloud REST API"
```

---

### Task 6: JiraSyncService

**Files:**
- Create: `app/services/jira_sync_service.rb`
- Create: `test/services/jira_sync_service_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/jira_sync_service_test.rb`:

```ruby
require "test_helper"

class JiraSyncServiceTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @jira_issues = [
      {
        key: "ELV-1",
        summary: "Existing task updated",
        status_category: "indeterminate",
        status_name: "In Progress",
        assignee_email: "one@example.com",
        url: "https://elvium.atlassian.net/browse/ELV-1"
      },
      {
        key: "ELV-2",
        summary: "New feature",
        status_category: "new",
        status_name: "To Do",
        assignee_email: "two@example.com",
        url: "https://elvium.atlassian.net/browse/ELV-2"
      },
      {
        key: "ELV-3",
        summary: "Done issue",
        status_category: "done",
        status_name: "Done",
        assignee_email: nil,
        url: "https://elvium.atlassian.net/browse/ELV-3"
      }
    ]
  end

  test "creates new tasks from Jira issues" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:fetch_issues, @jira_issues, ["ELV"])

    assert_difference -> { @project.tasks.count }, 2 do
      JiraSyncService.new(@project, client: mock_client).sync
    end

    mock_client.verify

    new_task = @project.tasks.find_by(external_reference: "ELV-2")
    assert_equal "ELV-2 New feature", new_task.name
    assert_equal "jira", new_task.external_type
    assert_equal "https://elvium.atlassian.net/browse/ELV-2", new_task.external_url
    assert_equal "two@example.com", new_task.assignee_email
    assert_equal "To Do", new_task.jira_status_name
    assert_equal "active", new_task.status
  end

  test "updates existing synced tasks" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:fetch_issues, @jira_issues, ["ELV"])

    JiraSyncService.new(@project, client: mock_client).sync

    mock_client.verify

    existing = tasks(:jira_task).reload
    assert_equal "ELV-1 Existing task updated", existing.name
    assert_equal "In Progress", existing.jira_status_name
    assert_equal "active", existing.status
  end

  test "marks done issues as done" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:fetch_issues, @jira_issues, ["ELV"])

    JiraSyncService.new(@project, client: mock_client).sync

    mock_client.verify

    done_task = @project.tasks.find_by(external_reference: "ELV-3")
    assert_equal "done", done_task.status
    assert_equal "Done", done_task.jira_status_name
  end

  test "does not touch local tasks" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:fetch_issues, @jira_issues, ["ELV"])

    JiraSyncService.new(@project, client: mock_client).sync

    mock_client.verify

    local = tasks(:local_task).reload
    assert_equal "Daily standup", local.name
    assert_nil local.external_type
  end

  test "handles empty response gracefully" do
    mock_client = Minitest::Mock.new
    mock_client.expect(:fetch_issues, [], ["ELV"])

    assert_nothing_raised do
      JiraSyncService.new(@project, client: mock_client).sync
    end

    mock_client.verify
  end

  test "handles name collision by appending key" do
    # Create a task that would collide with a synced name
    @project.tasks.create!(name: "ELV-99 Colliding name", external_type: nil)

    mock_client = Minitest::Mock.new
    mock_client.expect(:fetch_issues, [
      { key: "ELV-99", summary: "Colliding name", status_category: "new", status_name: "To Do", assignee_email: nil, url: "https://elvium.atlassian.net/browse/ELV-99" }
    ], ["ELV"])

    JiraSyncService.new(@project, client: mock_client).sync

    mock_client.verify

    synced = @project.tasks.find_by(external_reference: "ELV-99", external_type: "jira")
    assert synced.present?
    assert_equal "ELV-99 Colliding name [ELV-99]", synced.name
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/jira_sync_service_test.rb`
Expected: FAIL — `NameError: uninitialized constant JiraSyncService`

- [ ] **Step 3: Implement JiraSyncService**

Create `app/services/jira_sync_service.rb`:

```ruby
class JiraSyncService
  def initialize(project, client: nil)
    @project = project
    @client = client || JiraClient.new
  end

  def sync
    return unless @project.jira_connected?

    issues = @client.fetch_issues(@project.external_reference)
    return if issues.nil?

    issues.each do |issue|
      sync_issue(issue)
    end
  end

  private

  def sync_issue(issue)
    task = @project.tasks.find_or_initialize_by(
      external_reference: issue[:key],
      external_type: "jira"
    )

    task.assign_attributes(
      name: "#{issue[:key]} #{issue[:summary]}",
      external_url: issue[:url],
      assignee_email: issue[:assignee_email],
      jira_status_name: issue[:status_name],
      status: map_status(issue[:status_category])
    )

    task.save!
  rescue ActiveRecord::RecordNotUnique
    # Name collision with existing task — disambiguate
    task.name = "#{issue[:key]} #{issue[:summary]} [#{issue[:key]}]"
    task.save!
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[JiraSyncService] Failed to sync #{issue[:key]}: #{e.message}")
  end

  def map_status(status_category)
    case status_category
    when "done" then :done
    else :active
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/jira_sync_service_test.rb`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/jira_sync_service.rb test/services/jira_sync_service_test.rb
git commit -m "feat: add JiraSyncService to sync Jira issues as local tasks"
```

---

### Task 7: Background job and recurring schedule

**Files:**
- Create: `app/jobs/jira_sync_job.rb`
- Modify: `config/recurring.yml`

- [ ] **Step 1: Create the job**

Create `app/jobs/jira_sync_job.rb`:

```ruby
class JiraSyncJob < ApplicationJob
  queue_as :default

  def perform
    Project.where(external_type: "jira").find_each do |project|
      JiraSyncService.new(project).sync
    rescue => e
      Rails.logger.error("[JiraSyncJob] Failed to sync project #{project.id}: #{e.message}")
    end
  end
end
```

- [ ] **Step 2: Add to recurring schedule**

In `config/recurring.yml`, add under the `production:` key after the existing job:

```yaml
  jira_sync:
    class: JiraSyncJob
    schedule: every 15 minutes
```

- [ ] **Step 3: Commit**

```bash
git add app/jobs/jira_sync_job.rb config/recurring.yml
git commit -m "feat: add JiraSyncJob recurring every 15 minutes"
```

---

## Chunk 3: Controller and routes

### Task 8: JiraController with endpoints

**Files:**
- Create: `app/controllers/jira_controller.rb`
- Modify: `config/routes.rb`
- Create: `test/controllers/jira_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/controllers/jira_controller_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class JiraControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @project = projects(:jira_project)

    ENV["JIRA_DOMAIN"] = "test.atlassian.net"
    ENV["JIRA_EMAIL"] = "test@example.com"
    ENV["JIRA_API_TOKEN"] = "test-token"
  end

  test "projects returns Jira project list as JSON" do
    stub_request(:get, "https://test.atlassian.net/rest/api/3/project/search")
      .to_return(
        status: 200,
        body: { values: [{ key: "ELV", name: "Elvium", id: "10001" }], isLast: true }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    get jira_projects_path, as: :json

    assert_response :success
    data = JSON.parse(response.body)
    assert_equal 1, data.length
    assert_equal "ELV", data.first["key"]
  end

  test "projects returns empty array on Jira failure" do
    stub_request(:get, "https://test.atlassian.net/rest/api/3/project/search")
      .to_return(status: 500)

    get jira_projects_path, as: :json

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "tasks returns sorted task list for a project" do
    get jira_tasks_project_path(@project), as: :json

    assert_response :success
    data = JSON.parse(response.body)
    assert_kind_of Array, data
    # Jira task should be present
    assert data.any? { |t| t["external_reference"] == "ELV-1" }
  end

  test "tasks only returns jira-synced tasks" do
    get jira_tasks_project_path(@project), as: :json

    data = JSON.parse(response.body)
    # local_task fixture has no external_type — should not appear
    assert_not data.any? { |t| t["name"] == "Daily standup" }
  end

  test "sync triggers sync and redirects" do
    stub_request(:get, "https://test.atlassian.net/rest/api/3/search")
      .with(query: hash_including({ "jql" => /project = ELV/ }))
      .to_return(
        status: 200,
        body: { issues: [], total: 0, startAt: 0, maxResults: 100 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    post jira_sync_project_path(@project)

    assert_redirected_to project_path(@project)
  end

  test "sync requires admin" do
    sign_in_as(users(:two))

    post jira_sync_project_path(@project)

    assert_redirected_to root_path
  end

  test "projects requires admin" do
    sign_in_as(users(:two))

    get jira_projects_path, as: :json

    assert_redirected_to root_path
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/jira_controller_test.rb`
Expected: FAIL — routing error

- [ ] **Step 3: Add routes**

In `config/routes.rb`, add the Jira routes. Add inside the existing `resources :projects` block, inside the existing `member do` block:

Find this block:
```ruby
resources :projects do
  resources :tasks, only: [ :create, :destroy ], shallow: true
  member do
    patch :archive
    patch :unarchive
  end
end
```

Change it to:
```ruby
resources :projects do
  resources :tasks, only: [ :create, :destroy ], shallow: true
  member do
    patch :archive
    patch :unarchive
    get :jira_tasks, to: "jira#jira_tasks"
    post :jira_sync, to: "jira#sync"
  end
end
```

Also add the standalone Jira projects route after the `projects` block:

```ruby
# Jira integration
get "jira/projects", to: "jira#projects", as: :jira_projects
```

- [ ] **Step 4: Implement JiraController**

Create `app/controllers/jira_controller.rb`:

```ruby
class JiraController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!, only: [:projects, :sync]
  before_action :require_employee!, only: [:jira_tasks]
  before_action :set_project, only: [:jira_tasks, :sync]

  def projects
    client = JiraClient.new
    render json: client.fetch_projects
  end

  def jira_tasks
    tasks = @project.tasks.jira_synced.active

    sorted = sort_tasks_for_user(tasks, current_user)

    render json: sorted.map { |t|
      {
        id: t.id,
        name: t.name,
        external_reference: t.external_reference,
        external_type: t.external_type,
        status_name: t.jira_status_name,
        assignee_email: t.assignee_email
      }
    }
  end

  def sync
    JiraSyncService.new(@project).sync
    redirect_to project_path(@project), notice: "Jira sync complete."
  end

  private

  def set_project
    @project = current_workspace.projects.find(params[:id])
  end

  def sort_tasks_for_user(tasks, user)
    tasks.sort_by do |t|
      assigned_to_me = t.assignee_email == user.email_address ? 0 : 1
      status_order = jira_status_order(t.jira_status_name)
      [assigned_to_me, status_order, t.name.downcase]
    end
  end

  def jira_status_order(status_name)
    case status_name&.downcase
    when "in progress" then 0
    when "to do" then 1
    else 2
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/jira_controller_test.rb`
Expected: All 7 tests PASS

- [ ] **Step 6: Commit**

```bash
git add app/controllers/jira_controller.rb config/routes.rb test/controllers/jira_controller_test.rb
git commit -m "feat: add JiraController with projects, tasks, and sync endpoints"
```

---

## Chunk 4: Project form — Jira project mapping

### Task 9: Jira project dropdown on project form

**Files:**
- Modify: `app/views/projects/_form.html.erb`
- Create: `app/javascript/controllers/jira_project_select_controller.js`
- Modify: `app/controllers/projects_controller.rb`

- [ ] **Step 1: Create the Stimulus controller for fetching Jira projects**

Create `app/javascript/controllers/jira_project_select_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "status"]
  static values = { currentKey: String }

  connect() {
    this.loadProjects()
  }

  async loadProjects() {
    this.statusTarget.textContent = "Loading Jira projects..."

    try {
      const response = await fetch("/jira/projects", {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) {
        this.statusTarget.textContent = "Could not connect to Jira"
        return
      }

      const projects = await response.json()

      if (projects.length === 0) {
        this.statusTarget.textContent = "No Jira projects found"
        return
      }

      this.statusTarget.textContent = ""
      this.selectTarget.innerHTML = '<option value="">No Jira project</option>'

      projects.forEach(project => {
        const option = document.createElement("option")
        option.value = project.key
        option.textContent = `${project.key} — ${project.name}`
        if (project.key === this.currentKeyValue) {
          option.selected = true
        }
        this.selectTarget.appendChild(option)
      })

      this.selectTarget.disabled = false
    } catch (e) {
      this.statusTarget.textContent = "Could not connect to Jira"
    }
  }

  select(event) {
    const key = event.target.value
    const typeField = this.element.querySelector("[data-jira-type-field]")
    const refField = this.element.querySelector("[data-jira-ref-field]")

    if (typeField) typeField.value = key ? "jira" : ""
    if (refField) refField.value = key
  }
}
```

- [ ] **Step 2: Add Jira project dropdown to project form**

In `app/views/projects/_form.html.erb`, add before the submit section (before the `<div class="flex gap-2">` line). Insert this block:

```erb
  <div class="space-y-1" data-controller="jira-project-select" data-jira-project-select-current-key-value="<%= project.external_type == 'jira' ? project.external_reference : '' %>">
    <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Jira Project</label>
    <select data-jira-project-select-target="select" data-action="change->jira-project-select#select" class="m3-text-field w-full" disabled>
      <option value="">Loading...</option>
    </select>
    <span data-jira-project-select-target="status" class="text-xs" style="color: var(--color-on-surface-variant)"></span>
    <%= f.hidden_field :external_type, data: { jira_type_field: true } %>
    <%= f.hidden_field :external_reference, data: { jira_ref_field: true } %>
  </div>
```

- [ ] **Step 3: Permit external_type and external_reference in projects controller**

In `app/controllers/projects_controller.rb`, update `project_params`:

From:
```ruby
params.require(:project).permit(:name, :client_id, :color, :billable, :hourly_rate_cents,
                                :budget_type, :budget_cents, :budget_hours)
```

To:
```ruby
params.require(:project).permit(:name, :client_id, :color, :billable, :hourly_rate_cents,
                                :budget_type, :budget_cents, :budget_hours,
                                :external_type, :external_reference)
```

- [ ] **Step 4: Trigger initial sync on project create/update**

In `app/controllers/projects_controller.rb`, update `create` to enqueue sync:

From:
```ruby
if @project.save
  redirect_to projects_path, notice: "Project created."
```

To:
```ruby
if @project.save
  JiraSyncService.new(@project).sync if @project.jira_connected?
  redirect_to projects_path, notice: "Project created."
```

Update `update`:

From:
```ruby
if @project.update(project_params)
  redirect_to projects_path, notice: "Project updated."
```

To:
```ruby
if @project.update(project_params)
  JiraSyncService.new(@project).sync if @project.jira_connected? && @project.saved_change_to_external_reference?
  redirect_to projects_path, notice: "Project updated."
```

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/jira_project_select_controller.js app/views/projects/_form.html.erb app/controllers/projects_controller.rb
git commit -m "feat: add Jira project mapping dropdown to project form"
```

---

## Chunk 5: Timer bar — fuzzy search dropdown

### Task 10: Jira task search Stimulus controller

**Files:**
- Create: `app/javascript/controllers/jira_task_search_controller.js`

- [ ] **Step 1: Create the fuzzy search controller**

Create `app/javascript/controllers/jira_task_search_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "dropdown", "list", "taskId"]
  static values = { tasks: Array, jiraConnected: Boolean }

  connect() {
    this.clickOutside = this.clickOutside.bind(this)
    document.addEventListener("click", this.clickOutside)

    // If already connected to Jira (running timer), load tasks on page load
    if (this.jiraConnectedValue) {
      this.loadTasksForCurrentProject()
    }
  }

  disconnect() {
    document.removeEventListener("click", this.clickOutside)
  }

  async projectChanged(event) {
    const projectId = event.target.value
    this.jiraConnectedValue = false
    this.tasksValue = []

    if (!projectId) {
      this.hideTaskSelect(false)
      return
    }

    try {
      const response = await fetch(`/projects/${projectId}/jira_tasks`, {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) {
        this.hideTaskSelect(false)
        return
      }

      const tasks = await response.json()

      if (tasks.length > 0) {
        this.jiraConnectedValue = true
        this.tasksValue = tasks
        this.hideTaskSelect(true)
      } else {
        this.hideTaskSelect(false)
      }
    } catch (e) {
      this.hideTaskSelect(false)
    }
  }

  async loadTasksForCurrentProject() {
    const form = this.element.closest("form") || this.element
    const projectSelect = form.querySelector("select[name*='project_id']")
    if (!projectSelect || !projectSelect.value) return

    try {
      const response = await fetch(`/projects/${projectSelect.value}/jira_tasks`, {
        headers: { "Accept": "application/json" }
      })
      if (response.ok) {
        const tasks = await response.json()
        if (tasks.length > 0) {
          this.tasksValue = tasks
          this.jiraConnectedValue = true
          this.hideTaskSelect(true)
        }
      }
    } catch (e) {
      // silently fail
    }
  }

  focus() {
    if (!this.jiraConnectedValue || this.tasksValue.length === 0) return
    this.renderList()
    this.show()
  }

  filter() {
    if (!this.jiraConnectedValue) return
    this.renderList(this.inputTarget.value)
    this.show()
  }

  renderList(query = "") {
    if (!this.hasListTarget) return

    const tasks = this.fuzzyFilter(this.tasksValue, query)
    this.listTarget.innerHTML = ""

    if (tasks.length === 0) {
      const empty = document.createElement("div")
      empty.className = "px-3 py-2 text-sm"
      empty.style.color = "var(--color-on-surface-variant)"
      empty.textContent = "No matching tasks"
      this.listTarget.appendChild(empty)
      return
    }

    tasks.forEach(task => {
      const item = document.createElement("div")
      item.style.cssText = "padding: 8px 12px; cursor: pointer; display: flex; align-items: center; gap: 8px; transition: background 0.15s;"
      item.addEventListener("mouseenter", () => { item.style.background = "var(--color-surface-container-high)" })
      item.addEventListener("mouseleave", () => { item.style.background = "transparent" })

      const key = document.createElement("span")
      key.className = "text-xs font-semibold flex-shrink-0"
      key.style.color = "var(--color-primary)"
      key.textContent = task.external_reference || ""

      const summary = document.createElement("span")
      summary.className = "text-sm flex-1 truncate"
      summary.style.color = "var(--color-on-surface)"
      const nameWithoutKey = task.name.replace(`${task.external_reference} `, "")
      summary.textContent = nameWithoutKey

      item.appendChild(key)
      item.appendChild(summary)

      if (task.status_name) {
        const badge = document.createElement("span")
        badge.className = "text-xs px-1.5 py-0.5 rounded-full flex-shrink-0"
        badge.style.cssText = "background: var(--color-secondary-container); color: var(--color-on-secondary-container); font-size: 0.65rem;"
        badge.textContent = task.status_name
        item.appendChild(badge)
      }

      item.addEventListener("click", () => this.selectTask(task))
      this.listTarget.appendChild(item)
    })
  }

  selectTask(task) {
    if (this.hasInputTarget) {
      this.inputTarget.value = task.name
    }
    if (this.hasTaskIdTarget) {
      this.taskIdTarget.value = task.id
    }
    this.hide()

    // Trigger auto-save if available
    this.inputTarget.dispatchEvent(new Event("blur", { bubbles: true }))
  }

  fuzzyFilter(tasks, query) {
    if (!query || query.trim() === "") return tasks

    const q = query.toLowerCase()
    return tasks.filter(t => {
      const name = t.name.toLowerCase()
      const ref = (t.external_reference || "").toLowerCase()
      // Fuzzy match: all query chars appear in order within the name
      let qi = 0
      for (let i = 0; i < name.length && qi < q.length; i++) {
        if (name[i] === q[qi]) qi++
      }
      return qi === q.length || ref.includes(q)
    })
  }

  show() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.remove("hidden")
    }
  }

  hide() {
    if (this.hasDropdownTarget) {
      this.dropdownTarget.classList.add("hidden")
    }
  }

  clickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.hide()
    }
  }

  hideTaskSelect(hide) {
    const form = this.element.closest("form")
    if (!form) return
    const taskSelect = form.querySelector("[data-jira-task-select]")
    if (taskSelect) {
      taskSelect.style.display = hide ? "none" : ""
    }
  }

  keydown(event) {
    if (event.key === "Escape") {
      this.hide()
      event.preventDefault()
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add app/javascript/controllers/jira_task_search_controller.js
git commit -m "feat: add jira-task-search Stimulus controller with fuzzy filtering"
```

---

### Task 11: Wire timer bar to Jira task search

**Files:**
- Modify: `app/views/shared/_timer_bar.html.erb`

This task modifies all three description field contexts in the timer bar. Reference the surrounding code context rather than line numbers since the file may change.

- [ ] **Step 1: Update the running timer form**

In the running timer section (`<% if @running_timer %>`), make these changes:

**a)** On the form tag, add the `jira-task-search` controller:

Find:
```erb
<%= form_with url: update_running_timer_path, method: :patch, class: "flex items-center gap-2.5 flex-1 min-w-0", data: { controller: "auto-save" } do |f| %>
```

Replace with:
```erb
<%= form_with url: update_running_timer_path, method: :patch, class: "flex items-center gap-2.5 flex-1 min-w-0", data: { controller: "auto-save jira-task-search", jira_task_search_jira_connected_value: @running_timer.project&.jira_connected? || false } do |f| %>
```

**b)** Replace the description input div (the `<div>` with the pulsing indicator and text field) with:

Find:
```erb
      <div class="flex items-center gap-2.5 flex-1 min-w-0 px-5 py-2.5 rounded-full" style="border: 1px solid var(--color-primary); background: var(--color-surface-container-lowest);">
        <span class="relative flex h-2.5 w-2.5 flex-shrink-0">
          <span class="animate-ping absolute inline-flex h-full w-full rounded-full opacity-75" style="background: var(--color-primary)"></span>
          <span class="relative inline-flex rounded-full h-2.5 w-2.5" style="background: var(--color-primary)"></span>
        </span>
        <%= f.text_field "time_entry[description]", value: @running_timer.description,
            placeholder: "What are you working on?",
            class: "bg-transparent border-none flex-1 min-w-[120px] text-[0.9375rem] font-medium focus:outline-none",
            style: "color: var(--color-on-surface)",
            data: { action: "blur->auto-save#save" } %>
      </div>
```

Replace with:
```erb
      <div class="flex items-center gap-2.5 flex-1 min-w-0 px-5 py-2.5 rounded-full relative" style="border: 1px solid var(--color-primary); background: var(--color-surface-container-lowest);">
        <span class="relative flex h-2.5 w-2.5 flex-shrink-0">
          <span class="animate-ping absolute inline-flex h-full w-full rounded-full opacity-75" style="background: var(--color-primary)"></span>
          <span class="relative inline-flex rounded-full h-2.5 w-2.5" style="background: var(--color-primary)"></span>
        </span>
        <%= f.text_field "time_entry[description]", value: @running_timer.description,
            placeholder: "What are you working on?",
            class: "bg-transparent border-none flex-1 min-w-[120px] text-[0.9375rem] font-medium focus:outline-none",
            style: "color: var(--color-on-surface)",
            autocomplete: "off",
            data: { action: "blur->auto-save#save focus->jira-task-search#focus input->jira-task-search#filter keydown->jira-task-search#keydown", jira_task_search_target: "input" } %>
        <%= f.hidden_field "time_entry[task_id]", value: @running_timer.task_id, data: { jira_task_search_target: "taskId" } %>
        <div class="hidden absolute left-0 top-full mt-1 w-full rounded-xl shadow-lg z-50 max-h-64 overflow-y-auto" style="background: var(--color-surface-container); border: 1px solid var(--color-outline-variant);" data-jira-task-search-target="dropdown">
          <div data-jira-task-search-target="list"></div>
        </div>
      </div>
```

**c)** On the running timer project select, add the jira-task-search action:

Find:
```erb
data: { controller: "task-loader", action: "change->task-loader#load change->auto-save#save" }
```

Replace with:
```erb
data: { controller: "task-loader", action: "change->task-loader#load change->auto-save#save change->jira-task-search#projectChanged" }
```

**d)** On the running timer task select `<div>`, add `data-jira-task-select` and conditional hide:

Find the `<div class="m3-timer-pill-wrap">` that wraps the `time_entry[task_id]` select (the second pill wrap). Replace that opening div with:

```erb
<div class="m3-timer-pill-wrap" data-jira-task-select style="<%= @running_timer.project&.jira_connected? ? 'display:none' : '' %>">
```

- [ ] **Step 2: Update the start timer form**

In the inactive timer section (`<div data-timer-mode-target="timerMode">`), make these changes:

**a)** On the form tag, add the controller:

Find:
```erb
<%= form_with url: start_timer_path, method: :post, class: "flex items-center gap-2 w-full" do |f| %>
```

Replace with:
```erb
<%= form_with url: start_timer_path, method: :post, class: "flex items-center gap-2 w-full", data: { controller: "jira-task-search" } do |f| %>
```

**b)** Replace the description text field with a wrapper that includes the dropdown:

Find:
```erb
        <%= f.text_field :description, placeholder: "What are you working on?",
            class: "bg-transparent border-none flex-1 min-w-[120px] text-[0.9375rem] focus:outline-none",
            style: "color: var(--color-on-surface); --tw-placeholder-opacity: 1;",
            placeholder: "What are you working on?" %>
```

Replace with:
```erb
        <div class="relative flex-1 min-w-[120px]">
          <%= f.text_field :description, placeholder: "What are you working on?",
              class: "bg-transparent border-none w-full text-[0.9375rem] focus:outline-none",
              style: "color: var(--color-on-surface);",
              autocomplete: "off",
              data: { action: "focus->jira-task-search#focus input->jira-task-search#filter keydown->jira-task-search#keydown", jira_task_search_target: "input" } %>
          <%= f.hidden_field :task_id, data: { jira_task_search_target: "taskId" } %>
          <div class="hidden absolute left-0 top-full mt-1 w-full rounded-xl shadow-lg z-50 max-h-64 overflow-y-auto" style="background: var(--color-surface-container); border: 1px solid var(--color-outline-variant); min-width: 320px;" data-jira-task-search-target="dropdown">
            <div data-jira-task-search-target="list"></div>
          </div>
        </div>
```

**c)** On the start timer project select, add the jira-task-search action:

Find:
```erb
data: { controller: "task-loader", action: "change->task-loader#load" }
```

(This is the one in the timer mode section, NOT the manual mode one)

Replace with:
```erb
data: { controller: "task-loader", action: "change->task-loader#load change->jira-task-search#projectChanged" }
```

**d)** On the start timer task select div, add `data-jira-task-select`:

Find the `<div class="timer-desktop-only">` that wraps `f.select :task_id`. Replace the opening div with:

```erb
<div class="timer-desktop-only" data-jira-task-select>
```

- [ ] **Step 3: Update the manual entry form**

In the manual mode section (`<div data-timer-mode-target="manualMode">`), make these changes:

**a)** On the form tag, add the controller:

Find:
```erb
<%= form_with url: time_entries_path, method: :post, class: "flex items-center gap-2 w-full" do |f| %>
```

Replace with:
```erb
<%= form_with url: time_entries_path, method: :post, class: "flex items-center gap-2 w-full", data: { controller: "jira-task-search" } do |f| %>
```

**b)** Replace the description text field:

Find:
```erb
        <%= f.text_field "time_entry[description]", placeholder: "What did you work on?",
            class: "bg-transparent border-none flex-1 min-w-[100px] text-[0.9375rem] focus:outline-none",
            style: "color: var(--color-on-surface)" %>
```

Replace with:
```erb
        <div class="relative flex-1 min-w-[100px]">
          <%= f.text_field "time_entry[description]", placeholder: "What did you work on?",
              class: "bg-transparent border-none w-full text-[0.9375rem] focus:outline-none",
              style: "color: var(--color-on-surface)",
              autocomplete: "off",
              data: { action: "focus->jira-task-search#focus input->jira-task-search#filter keydown->jira-task-search#keydown", jira_task_search_target: "input" } %>
          <%= f.hidden_field "time_entry[task_id]", data: { jira_task_search_target: "taskId" } %>
          <div class="hidden absolute left-0 top-full mt-1 w-full rounded-xl shadow-lg z-50 max-h-64 overflow-y-auto" style="background: var(--color-surface-container); border: 1px solid var(--color-outline-variant); min-width: 320px;" data-jira-task-search-target="dropdown">
            <div data-jira-task-search-target="list"></div>
          </div>
        </div>
```

**c)** On the manual entry project select, add the jira-task-search action:

Find the second `task-loader` controller reference (in the manual mode section):
```erb
data: { controller: "task-loader", action: "change->task-loader#load" }
```

Replace with:
```erb
data: { controller: "task-loader", action: "change->task-loader#load change->jira-task-search#projectChanged" }
```

**d)** On the manual entry task select div, add `data-jira-task-select`:

Find the `<div class="timer-desktop-only">` that wraps `time_entry[task_id]` in the manual mode section. Replace the opening div with:

```erb
<div class="timer-desktop-only" data-jira-task-select>
```

- [ ] **Step 4: Commit**

```bash
git add app/views/shared/_timer_bar.html.erb
git commit -m "feat: wire timer bar description fields to Jira task search dropdown"
```

---

## Chunk 6: Verification

### Task 12: Verify .env loading and full test suite

- [ ] **Step 1: Verify dotenv loads**

Run: `bin/rails runner "puts ENV['JIRA_DOMAIN']"`
Expected: `elvium.atlassian.net`

If it outputs blank, add to `config/application.rb` before `Bundler.require`:
```ruby
Dotenv::Rails.load
```

- [ ] **Step 2: Run full test suite**

Run: `bin/rails test`
Expected: All tests pass

- [ ] **Step 3: Manual verification**

Start: `bin/dev`

1. Navigate to `/projects/new` — Jira Project dropdown should load and show Jira projects
2. Create a project mapped to a Jira project — tasks should sync immediately
3. Visit the project page — synced Jira tasks should appear
4. On the timer bar, select the Jira-mapped project — Task dropdown should hide
5. Click the description field — fuzzy search dropdown should appear with Jira tasks
6. Type to filter — dropdown should narrow results
7. Select a task — description should fill, dropdown should close
8. Switch to a non-Jira project — Task dropdown should reappear, no Jira dropdown on description
9. Start a timer with a Jira task selected — running timer should show the task
10. The running timer description field should also show the Jira dropdown on focus

- [ ] **Step 4: Fix any issues found and commit**

```bash
git add -A
git commit -m "fix: resolve issues from Jira integration verification"
```
