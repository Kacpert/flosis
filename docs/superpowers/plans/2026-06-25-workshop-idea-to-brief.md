# Workshop — Idea → Brief Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Workshop tab whose "Idea → Brief" pipeline turns a feature idea (new, or an existing design-sprint Jira task) into a versioned brief via an AI Product-Owner conversation, then writes the brief back to Jira and marks the issue "Briefed"; and relocate the existing Brief → Task (breakdown) flow under Workshop with a Jira-update button.

**Architecture:** Reuse the existing streaming-chat machinery (`ChatStreaming` concern, `ClaudeCliService`, `task_chat` Stimulus controller) with a new `purpose: "brief"`. Add the first Jira-WRITE capability to `JiraClient`. Briefs are a new versioned model. A daily job scans the elvium repo to fill a per-project `features_summary`. Admin-only, gated by a `workshop_enabled` workspace toggle.

**Tech Stack:** Rails 8.1.2, Ruby 3.4.1, Minitest, Turbo/Stimulus, Tailwind (`m3-*` classes), Solid Queue (`config/recurring.yml`), `Net::HTTP` for Jira, `ClaudeCliService` (claude CLI), WebMock for HTTP stubs in tests.

## Global Constraints

- Ruby 3.4.1 / Rails 8.1.2. Minitest only (NO RSpec). Minitest here has NO `Object#stub` — stub by swapping singleton/instance methods manually (save original, redefine, restore in `ensure`), as in `test/jobs/pr_review_job_test.rb`.
- App timezone is **Warsaw** (`config.time_zone = "Warsaw"`); cron in `recurring.yml` is evaluated in app TZ. ActiveRecord stores UTC.
- Jira auth is GLOBAL env vars (`JIRA_DOMAIN`, `JIRA_EMAIL`, `JIRA_API_TOKEN`) via `JiraClient.new`; there is NO per-workspace Jira token.
- Jira HTTP: `Net::HTTP`, Basic auth `Base64.strict_encode64("#{email}:#{token}")`, `Accept: application/json`, base `https://#{domain}`. Reuse the private `get`/`post` style; add a private `put` mirroring `post`.
- Claude CLI may print auth/quota errors as PLAIN TEXT rather than raising. NEVER treat such output as a valid result. Reuse the PR-reviewer failure-marker approach (`app/jobs/pr_review_job.rb` `CLI_FAILURE_MARKERS` / `cli_failed?`).
- No silent success on any Jira write: a failed write must surface an error and must NOT flip a brief to "briefed".
- Use existing CSS conventions: `m3-*` classes (DaisyUI is NOT wired in). Match the sidebar/nav patterns in `app/views/layouts/application.html.erb`.
- Feature-toggle pattern: boolean column on `workspaces`, permit in `workspace_settings_params`, checkbox in `workspace_settings/show`, guard views with `current_workspace.<flag>?` and controllers with `require_admin!` + flag check.
- Commit after every task. Branch is `production` (deploy branch); commit there as the existing history does.

## Spec deviation (decided while planning)

The spec allowed `Brief.task_id` to be null for the new-idea path. But `ChatStreaming` is tightly coupled to a persisted `@task` (`@task.chat_sessions`, `@task.name`, `@task.external_reference`). To reuse it unchanged, the **new-idea path creates a local Gold `Task` up front** (`external_type` nil, no `external_reference`), so the brief chat always has a `@task`. The Jira issue is still created only at commit; the Task's `external_reference`/`external_url`/`external_type` are backfilled then. Therefore `Brief.task_id` is **NOT NULL**, and `idea_title`/`idea_body`/`project_id` columns on Brief are unnecessary. Versions are scoped per task.

---

## File Structure

- `db/migrate/…_create_briefs.rb` — Brief table.
- `db/migrate/…_add_workshop_fields.rb` — `projects.features_summary`, `projects.features_summary_updated_at`, `projects.context_info`; `workspaces.workshop_enabled`, `workspaces.jira_ai_actions_field_id`.
- `app/models/brief.rb` — versioned brief, `next_version_for`, `mark_briefed!`.
- `app/models/task.rb` — add `has_many :briefs`, `latest_brief`.
- `app/models/project.rb` — (no code change needed beyond columns; add `briefable_tasks`/design-sprint scope helper here).
- `app/services/jira_client.rb` — add write methods: `create_issue`, `update_issue_description`, `add_ai_action`, `fetch_field_id`, private `put`.
- `app/services/jira_writer.rb` — orchestrates a brief→Jira commit (create-or-update + set AI action + field-id discovery/caching), returns a result hash. Keeps controller thin.
- `app/controllers/workshop_controller.rb` — Workshop landing + Idea→Brief step pages (admin + toggle gate).
- `app/controllers/brief_chat_sessions_controller.rb` — `purpose: "brief"`, includes `ChatStreaming`; builds PO prompt; extracts `<brief>` blocks.
- `app/controllers/brief_commits_controller.rb` — POST: commit a brief version to Jira.
- `app/controllers/task_breakdowns_controller.rb` — add `update_jira` action (Brief→Task Jira push).
- `app/jobs/project_features_scan_job.rb` — daily repo scan → `features_summary`.
- `app/views/workshop/*` — landing, idea picker, brief pipeline page.
- `app/views/layouts/application.html.erb` — Workshop sidebar item.
- `app/views/workspace_settings/show.html.erb` — Workshop toggle.
- `app/controllers/workspace_settings_controller.rb` — permit `:workshop_enabled`.
- `app/views/projects/_form.html.erb` — `context_info` textarea + read-only features summary.
- `app/controllers/projects_controller.rb` — permit `:context_info`.
- `config/routes.rb` — Workshop routes + brief chat + brief commit + breakdown `update_jira`.
- `config/recurring.yml` — `project_features_scan`.
- Tests under `test/models`, `test/services`, `test/jobs`, `test/controllers`.

---

## Task 1: Migrations — Brief table + Workshop fields

**Files:**
- Create: `db/migrate/20260625000001_create_briefs.rb`
- Create: `db/migrate/20260625000002_add_workshop_fields.rb`
- Modify: `db/schema.rb` (auto via migrate)

**Interfaces:**
- Produces: `briefs` table (`task_id`, `workspace_id`, `chat_session_id` nullable, `version` int, `content` text, `status` string default "draft", `briefed_at` datetime); `projects.features_summary` (text), `projects.features_summary_updated_at` (datetime), `projects.context_info` (text); `workspaces.workshop_enabled` (bool default false), `workspaces.jira_ai_actions_field_id` (string).

- [ ] **Step 1: Write the create_briefs migration**

```ruby
class CreateBriefs < ActiveRecord::Migration[8.1]
  def change
    create_table :briefs do |t|
      t.references :task, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :chat_session, null: true, foreign_key: true
      t.integer :version, null: false, default: 1
      t.text :content, null: false
      t.string :status, null: false, default: "draft"
      t.datetime :briefed_at
      t.timestamps
    end
    add_index :briefs, [:task_id, :version], unique: true
  end
end
```

- [ ] **Step 2: Write the add_workshop_fields migration**

```ruby
class AddWorkshopFields < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :features_summary, :text
    add_column :projects, :features_summary_updated_at, :datetime
    add_column :projects, :context_info, :text
    add_column :workspaces, :workshop_enabled, :boolean, null: false, default: false
    add_column :workspaces, :jira_ai_actions_field_id, :string
  end
end
```

- [ ] **Step 3: Run the migrations**

Run: `bin/rails db:migrate`
Expected: both migrations run; `db/schema.rb` updated with the new table and columns. No errors.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/20260625000001_create_briefs.rb db/migrate/20260625000002_add_workshop_fields.rb db/schema.rb
git commit -m "feat: migrations for Brief model + Workshop project/workspace fields"
```

---

## Task 2: Brief model

**Files:**
- Create: `app/models/brief.rb`
- Modify: `app/models/task.rb` (add association + `latest_brief`)
- Test: `test/models/brief_test.rb`

**Interfaces:**
- Consumes: `briefs` table (Task 1).
- Produces:
  - `Brief.next_version_for(task)` → Integer (max version for task + 1, or 1).
  - `Brief#mark_briefed!` → sets `status: "briefed"`, `briefed_at: Time.current`, saves.
  - `Brief.draft` / `Brief.briefed` scopes; `Brief.newest_first` scope.
  - `Task#latest_brief` → most recent Brief for the task or nil.
  - `Task#briefs` association.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class BriefTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:jira_one) # an existing fixture task in workspace one's jira project
    @workspace = @task.project.workspace
  end

  test "next_version_for starts at 1 and increments" do
    assert_equal 1, Brief.next_version_for(@task)
    Brief.create!(task: @task, workspace: @workspace, version: 1, content: "v1")
    assert_equal 2, Brief.next_version_for(@task)
  end

  test "mark_briefed! sets status and timestamp" do
    b = Brief.create!(task: @task, workspace: @workspace, version: 1, content: "x")
    assert_equal "draft", b.status
    b.mark_briefed!
    assert_equal "briefed", b.status
    assert_not_nil b.briefed_at
  end

  test "latest_brief returns the most recent" do
    Brief.create!(task: @task, workspace: @workspace, version: 1, content: "old")
    newer = Brief.create!(task: @task, workspace: @workspace, version: 2, content: "new")
    assert_equal newer, @task.latest_brief
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/brief_test.rb`
Expected: FAIL — `NameError: uninitialized constant Brief` (or `NoMethodError` for `latest_brief`).

- [ ] **Step 3: Write the Brief model**

```ruby
class Brief < ApplicationRecord
  belongs_to :task
  belongs_to :workspace
  belongs_to :chat_session, optional: true

  STATUSES = %w[draft briefed].freeze

  validates :content, presence: true
  validates :version, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :newest_first, -> { order(version: :desc) }
  scope :draft, -> { where(status: "draft") }
  scope :briefed, -> { where(status: "briefed") }

  def self.next_version_for(task)
    (where(task: task).maximum(:version) || 0) + 1
  end

  def mark_briefed!
    update!(status: "briefed", briefed_at: Time.current)
  end
end
```

- [ ] **Step 4: Add the Task association and helper**

In `app/models/task.rb`, add to the associations block (after `has_many :task_drafts`):

```ruby
  has_many :briefs, dependent: :destroy
```

And add the helper method (after `latest_breakdown`):

```ruby
  # The most recent brief (any status) for this task.
  def latest_brief
    briefs.newest_first.first
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/brief_test.rb`
Expected: PASS (3 runs, 0 failures). If the `tasks(:jira_one)` fixture name differs, open `test/fixtures/tasks.yml` and use an existing jira-synced task fixture whose project belongs to `workspaces(:one)`.

- [ ] **Step 6: Commit**

```bash
git add app/models/brief.rb app/models/task.rb test/models/brief_test.rb
git commit -m "feat: Brief model with per-task versioning and mark_briefed!"
```

---

## Task 3: JiraClient write methods + field discovery

**Files:**
- Modify: `app/services/jira_client.rb` (add `create_issue`, `update_issue_description`, `add_ai_action`, `fetch_field_id`, private `put`)
- Test: `test/services/jira_client_write_test.rb`

**Interfaces:**
- Consumes: existing private `get`/`post` and Basic-auth pattern.
- Produces (all return a result hash, never raise on HTTP error):
  - `create_issue(project_key:, summary:, description_text:, issue_type: "Task")` → `{ ok: true, key:, url: }` or `{ ok: false, error: }`.
  - `update_issue_description(issue_key:, description_text:)` → `{ ok: true }` or `{ ok: false, error: }`.
  - `add_ai_action(issue_key:, field_id:, value:)` → `{ ok: true }` or `{ ok: false, error: }`. Sets the multi-select custom field to include `value` (sends `[{ "value" => value }]`).
  - `fetch_field_id(name)` → String field id (e.g. `"customfield_10050"`) or nil. Calls `GET /rest/api/3/field` and matches by case-insensitive name.
  - `description_doc(text)` private helper → minimal ADF doc hash for a plain-text description.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class JiraClientWriteTest < ActiveSupport::TestCase
  def client
    JiraClient.new(domain: "ex.atlassian.net", email: "e@x.com", api_token: "tok")
  end

  test "create_issue posts and returns key + url" do
    stub_request(:post, "https://ex.atlassian.net/rest/api/3/issue")
      .to_return(status: 201, body: { key: "PROJ-99" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    res = client.create_issue(project_key: "PROJ", summary: "Hi", description_text: "Body", issue_type: "Task")
    assert res[:ok]
    assert_equal "PROJ-99", res[:key]
    assert_equal "https://ex.atlassian.net/browse/PROJ-99", res[:url]
  end

  test "create_issue surfaces an error on failure" do
    stub_request(:post, "https://ex.atlassian.net/rest/api/3/issue")
      .to_return(status: 400, body: { errorMessages: ["nope"] }.to_json)
    res = client.create_issue(project_key: "PROJ", summary: "Hi", description_text: "Body")
    assert_not res[:ok]
    assert res[:error].present?
  end

  test "update_issue_description PUTs and returns ok" do
    stub_request(:put, "https://ex.atlassian.net/rest/api/3/issue/PROJ-5")
      .to_return(status: 204, body: "")
    res = client.update_issue_description(issue_key: "PROJ-5", description_text: "New")
    assert res[:ok]
  end

  test "add_ai_action PUTs the custom field value" do
    stub_request(:put, "https://ex.atlassian.net/rest/api/3/issue/PROJ-5")
      .with(body: hash_including("fields" => { "customfield_10050" => [{ "value" => "Briefed" }] }))
      .to_return(status: 204, body: "")
    res = client.add_ai_action(issue_key: "PROJ-5", field_id: "customfield_10050", value: "Briefed")
    assert res[:ok]
  end

  test "fetch_field_id matches by name case-insensitively" do
    stub_request(:get, "https://ex.atlassian.net/rest/api/3/field")
      .to_return(status: 200,
                 body: [{ id: "customfield_10050", name: "AI actions" }].to_json,
                 headers: { "Content-Type" => "application/json" })
    assert_equal "customfield_10050", client.fetch_field_id("AI actions")
    assert_equal "customfield_10050", client.fetch_field_id("ai ACTIONS")
    assert_nil client.fetch_field_id("Nope")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/jira_client_write_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'create_issue'`.

- [ ] **Step 3: Implement the write methods**

In `app/services/jira_client.rb`, add these PUBLIC methods (after `download_attachment`, before `private`):

```ruby
  # ---- writes (use the same global creds) ------------------------------

  def create_issue(project_key:, summary:, description_text:, issue_type: "Task")
    body = {
      fields: {
        project: { key: project_key },
        summary: summary.to_s,
        issuetype: { name: issue_type },
        description: description_doc(description_text)
      }
    }
    data = post_raw("/rest/api/3/issue", body)
    return { ok: false, error: data[:error] } unless data[:ok]
    key = data[:json]["key"]
    { ok: true, key: key, url: "https://#{@domain}/browse/#{key}" }
  end

  def update_issue_description(issue_key:, description_text:)
    body = { fields: { description: description_doc(description_text) } }
    res = put("/rest/api/3/issue/#{issue_key}", body)
    res[:ok] ? { ok: true } : { ok: false, error: res[:error] }
  end

  def add_ai_action(issue_key:, field_id:, value:)
    body = { fields: { field_id => [{ "value" => value }] } }
    res = put("/rest/api/3/issue/#{issue_key}", body)
    res[:ok] ? { ok: true } : { ok: false, error: res[:error] }
  end

  def fetch_field_id(name)
    data = get("/rest/api/3/field")
    return nil unless data.is_a?(Array)
    field = data.find { |f| f["name"].to_s.casecmp?(name.to_s) }
    field && field["id"]
  end
```

Add these PRIVATE helpers (with the other private methods):

```ruby
  # Minimal ADF document wrapping plain text in a single paragraph.
  def description_doc(text)
    {
      type: "doc",
      version: 1,
      content: [
        { type: "paragraph", content: [{ type: "text", text: text.to_s }] }
      ]
    }
  end

  # POST that distinguishes success from failure (unlike #post, which returns
  # nil on error). Used by writes that need the error surfaced.
  def post_raw(path, body)
    response = http_request(Net::HTTP::Post, path, body)
    if response.is_a?(Net::HTTPSuccess)
      { ok: true, json: (JSON.parse(response.body) rescue {}) }
    else
      { ok: false, error: "#{response.code} #{response.message}" }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    { ok: false, error: e.message }
  end

  def put(path, body)
    response = http_request(Net::HTTP::Put, path, body)
    if response.is_a?(Net::HTTPSuccess)
      { ok: true }
    else
      { ok: false, error: "#{response.code} #{response.message}" }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    { ok: false, error: e.message }
  end

  # Shared request builder for write verbs.
  def http_request(verb_class, path, body)
    uri = URI("https://#{@domain}#{path}")
    request = verb_class.new(uri)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{@email}:#{@api_token}")}"
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = body.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    http.request(request)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/jira_client_write_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/jira_client.rb test/services/jira_client_write_test.rb
git commit -m "feat: JiraClient write methods (create/update issue, set AI-actions field)"
```

---

## Task 4: JiraWriter service (commit a brief to Jira)

**Files:**
- Create: `app/services/jira_writer.rb`
- Test: `test/services/jira_writer_test.rb`

**Interfaces:**
- Consumes: `JiraClient` write methods (Task 3); `Brief` (Task 2); `Workspace#jira_ai_actions_field_id` (Task 1).
- Produces:
  - `JiraWriter.new(workspace:, client: JiraClient.new)`.
  - `#commit_brief(brief)` → `{ ok: true, key:, url: }` or `{ ok: false, error: }`. For a task with no `external_reference`, CREATES a Jira issue (project key = `task.project.external_reference`) and backfills `task.external_reference`/`external_url`/`external_type`. For a task that already has `external_reference`, UPDATES the description. Then sets the "AI actions" field to "Briefed" (discovering + caching the field id on the workspace if absent). On any failure, returns `{ ok: false, error: }` and does NOT call `brief.mark_briefed!` (the caller does that only on ok).
  - `#ai_actions_field_id` → cached id or freshly fetched+stored, or nil.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class JiraWriterTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = @workspace.projects.create!(name: "JW", color: "#111111",
      external_type: "jira", external_reference: "JW")
    @workspace.update!(jira_ai_actions_field_id: "customfield_10050")
  end

  # Minimal fake client recording calls.
  def fake_client(create: { ok: true, key: "JW-1", url: "u" },
                  update: { ok: true }, action: { ok: true })
    c = Object.new
    calls = { create: 0, update: 0, action: nil }
    c.define_singleton_method(:create_issue) { |**_k| calls[:create] += 1; create }
    c.define_singleton_method(:update_issue_description) { |**_k| calls[:update] += 1; update }
    c.define_singleton_method(:add_ai_action) { |**k| calls[:action] = k; action }
    c.define_singleton_method(:fetch_field_id) { |_n| "customfield_10050" }
    c.define_singleton_method(:calls) { calls }
    c
  end

  test "new-idea task creates an issue and backfills the reference" do
    task = @project.tasks.create!(name: "Idea")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "concept")
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)
    assert res[:ok], res.inspect
    assert_equal 1, c.calls[:create]
    assert_equal 0, c.calls[:update]
    assert_equal "JW-1", task.reload.external_reference
    assert_equal "jira", task.external_type
    assert_equal "Briefed", c.calls[:action][:value]
  end

  test "existing task updates the description" do
    task = @project.tasks.create!(name: "JW-7 Existing", external_type: "jira", external_reference: "JW-7")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "concept")
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)
    assert res[:ok]
    assert_equal 0, c.calls[:create]
    assert_equal 1, c.calls[:update]
  end

  test "a failed write returns not-ok and does not mark briefed" do
    task = @project.tasks.create!(name: "JW-7 Existing", external_type: "jira", external_reference: "JW-7")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "x")
    c = fake_client(update: { ok: false, error: "403 Forbidden" })
    res = JiraWriter.new(workspace: @workspace, client: c).commit_brief(brief)
    assert_not res[:ok]
    assert_equal "403 Forbidden", res[:error]
  end

  test "missing field id is discovered and cached on the workspace" do
    @workspace.update!(jira_ai_actions_field_id: nil)
    task = @project.tasks.create!(name: "JW-7 Existing", external_type: "jira", external_reference: "JW-7")
    brief = Brief.create!(task: task, workspace: @workspace, version: 1, content: "x")
    JiraWriter.new(workspace: @workspace, client: fake_client).commit_brief(brief)
    assert_equal "customfield_10050", @workspace.reload.jira_ai_actions_field_id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/jira_writer_test.rb`
Expected: FAIL — `NameError: uninitialized constant JiraWriter`.

- [ ] **Step 3: Implement JiraWriter**

```ruby
# Commits a Brief back to Jira: creates the issue (new idea) or updates the
# description (existing task), then sets the "AI actions" field to "Briefed".
# Never raises on a Jira failure — returns { ok: false, error: } so the caller
# can keep the brief in Gold and surface the error instead of silently
# "succeeding". The caller marks the brief briefed ONLY when ok is true.
class JiraWriter
  AI_ACTION_FIELD_NAME = "AI actions".freeze
  BRIEFED_VALUE = "Briefed".freeze

  def initialize(workspace:, client: JiraClient.new)
    @workspace = workspace
    @client = client
  end

  def commit_brief(brief)
    task = brief.task

    if task.external_reference.present?
      res = @client.update_issue_description(issue_key: task.external_reference, description_text: brief.content)
      return res unless res[:ok]
      key = task.external_reference
      url = task.external_url
    else
      project_key = task.project.external_reference
      return { ok: false, error: "Project is not linked to Jira" } if project_key.blank?

      res = @client.create_issue(project_key: project_key, summary: task.name, description_text: brief.content)
      return res unless res[:ok]
      key = res[:key]
      url = res[:url]
      task.update!(external_reference: key, external_url: url, external_type: "jira")
    end

    field_id = ai_actions_field_id
    if field_id.present?
      action = @client.add_ai_action(issue_key: key, field_id: field_id, value: BRIEFED_VALUE)
      return { ok: false, error: "Issue saved but couldn't set 'AI actions': #{action[:error]}" } unless action[:ok]
    else
      return { ok: false, error: "Couldn't find the '#{AI_ACTION_FIELD_NAME}' field in Jira" }
    end

    { ok: true, key: key, url: url }
  end

  def ai_actions_field_id
    return @workspace.jira_ai_actions_field_id if @workspace.jira_ai_actions_field_id.present?

    id = @client.fetch_field_id(AI_ACTION_FIELD_NAME)
    @workspace.update_column(:jira_ai_actions_field_id, id) if id.present?
    id
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/jira_writer_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/jira_writer.rb test/services/jira_writer_test.rb
git commit -m "feat: JiraWriter commits a brief to Jira and marks the AI-actions field"
```

---

## Task 5: Workspace toggle + project context field plumbing

**Files:**
- Modify: `app/controllers/workspace_settings_controller.rb` (permit `:workshop_enabled`)
- Modify: `app/views/workspace_settings/show.html.erb` (Workshop toggle)
- Modify: `app/controllers/projects_controller.rb` (permit `:context_info`)
- Modify: `app/views/projects/_form.html.erb` (context_info textarea + read-only features summary)
- Test: `test/controllers/workspace_settings_controller_test.rb` (add a toggle test; create file if absent)

**Interfaces:**
- Consumes: `workspaces.workshop_enabled`, `projects.context_info`, `projects.features_summary` (Task 1).
- Produces: admins can enable Workshop and edit a project's context.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class WorkspaceSettingsControllerTest < ActionDispatch::IntegrationTest
  test "admin can enable workshop" do
    sign_in_as(users(:one)) # admin in workspace one
    patch workspace_settings_path, params: { workspace: { workshop_enabled: "1" } }
    assert workspaces(:one).reload.workshop_enabled
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: FAIL — `workshop_enabled` not permitted, so it stays false. (If a `sign_in_as` helper name differs, copy the sign-in approach from `test/controllers/reports/project_reports_controller_test.rb`.)

- [ ] **Step 3: Permit the param**

In `app/controllers/workspace_settings_controller.rb`, add `:workshop_enabled` to the permit list:

```ruby
    permitted = params.require(:workspace).permit(
      :clients_enabled, :discord_channel_id, :discord_user_token,
      :github_repo, :github_token, :pr_review_enabled, :workshop_enabled
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Add the Workshop toggle to the settings view**

In `app/views/workspace_settings/show.html.erb`, near the existing `clients_enabled` checkbox block, add a parallel block (match the surrounding markup exactly — this is the Clients-style row):

```erb
<div class="m3-field">
  <label class="m3-checkbox">
    <%= f.check_box :workshop_enabled %>
    <span>Enable Workshop</span>
  </label>
  <p class="m3-field-hint">Idea → Brief pipeline and Brief → Task, with Jira write-back.</p>
</div>
```

(Open the file first and mirror the exact wrapper classes used by the Clients toggle so it renders consistently.)

- [ ] **Step 6: Permit context_info and add the project form fields**

In `app/controllers/projects_controller.rb`, add `:context_info` to the project params permit list (find the existing `params.require(:project).permit(...)`).

In `app/views/projects/_form.html.erb`, add (matching existing field markup):

```erb
<div class="m3-field">
  <%= f.label :context_info, "Project context (for AI briefing)" %>
  <%= f.text_area :context_info, rows: 6,
        placeholder: "Who the users are, the main architecture, and the goal — e.g. 'ATS + HR app; goal: …'" %>
  <p class="m3-field-hint">Always editable. The AI reads this before briefing.</p>
</div>

<% if @project.persisted? && @project.features_summary.present? %>
  <div class="m3-field">
    <label>Auto-generated features summary</label>
    <pre class="m3-readonly"><%= @project.features_summary %></pre>
    <p class="m3-field-hint">Updated <%= @project.features_summary_updated_at&.strftime("%Y-%m-%d %H:%M") %> by the daily scan.</p>
  </div>
<% end %>
```

- [ ] **Step 7: Run the full controller test once more + a manual sanity check**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS. (Views aren't unit-tested here; they're covered by the Workshop controller test in Task 8.)

- [ ] **Step 8: Commit**

```bash
git add app/controllers/workspace_settings_controller.rb app/views/workspace_settings/show.html.erb app/controllers/projects_controller.rb app/views/projects/_form.html.erb test/controllers/workspace_settings_controller_test.rb
git commit -m "feat: workshop_enabled toggle + project context_info field"
```

---

## Task 6: BriefChatSessionsController (the PO conversation)

**Files:**
- Create: `app/controllers/brief_chat_sessions_controller.rb`
- Modify: `app/models/chat_session.rb` (add "brief" to PURPOSES)
- Modify: `config/routes.rb` (nested brief_chat_session route)
- Test: `test/controllers/brief_chat_sessions_controller_test.rb`

**Interfaces:**
- Consumes: `ChatStreaming` concern (`create`/`message`/`show`/`destroy`, `build_initial_prompt`, `extract_and_save_results`, `set_task`, `ticket_title`, `build_comments_section`, `build_attachments_section`); `Brief.next_version_for` (Task 2); project `context_info` / `features_summary` (Task 1).
- Produces:
  - `CHAT_PURPOSE = "brief"`.
  - `#extract_and_save_results(text)` parses `<brief>…</brief>` blocks and creates a `Brief` per block (`version: Brief.next_version_for(@task)`, `workspace: current_workspace`, `chat_session: @chat_session`, `status: "draft"`).
  - `#build_initial_prompt` — the skeptical-PO prompt fed project context + features summary + ticket/idea, instructing selective business-logic challenge and a final `<brief>` block.
  - `Brief.extract_briefs(text)` class-method (or inline regex) returning array of brief strings.

- [ ] **Step 1: Add "brief" to ChatSession PURPOSES**

In `app/models/chat_session.rb`:

```ruby
  PURPOSES = %w[refine breakdown brief].freeze
```

- [ ] **Step 2: Add the route**

In `config/routes.rb`, inside the `resources :jira_tasks do … end` block (next to `breakdown_chat_session`):

```ruby
    resource :brief_chat_session, only: [:create, :show, :destroy] do
      post :message
    end
    resources :briefs, only: [:index]
```

- [ ] **Step 3: Write the failing test**

```ruby
require "test_helper"

class BriefChatSessionsControllerTest < ActiveSupport::TestCase
  # Unit-test the result extraction directly (SSE is covered by integration
  # of the existing chat controllers). Instantiate the controller and call the
  # private method with a fabricated @task + @chat_session.
  setup do
    @workspace = workspaces(:one)
    @project = @workspace.projects.create!(name: "BC", color: "#222222",
      external_type: "jira", external_reference: "BC")
    @task = @project.tasks.create!(name: "BC-1 Thing", external_type: "jira", external_reference: "BC-1")
  end

  test "extract_and_save_results creates a versioned Brief per <brief> block" do
    controller = BriefChatSessionsController.new
    controller.instance_variable_set(:@task, @task)
    controller.instance_variable_set(:@current_workspace, @workspace)
    def controller.current_workspace; @current_workspace; end
    controller.instance_variable_set(:@chat_session, nil)

    text = "lead-in <brief>The concept is X. Value: Y.</brief> trailing"
    controller.send(:extract_and_save_results, text)

    assert_equal 1, @task.briefs.count
    b = @task.briefs.first
    assert_equal 1, b.version
    assert_match "concept is X", b.content
    assert_equal "draft", b.status
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bin/rails test test/controllers/brief_chat_sessions_controller_test.rb`
Expected: FAIL — `NameError: uninitialized constant BriefChatSessionsController`.

- [ ] **Step 5: Implement the controller**

```ruby
# Chat session that acts as a skeptical Product Owner: it gathers a brief and
# challenges business requirements (only when it makes sense), focusing on user
# value and the best option given the existing app. Shares all SSE/persistence
# plumbing with the other chats via ChatStreaming; differs only in the prompt
# and how results are extracted. Result blocks are <brief>…</brief>, saved as a
# versioned Brief (status "draft").
class BriefChatSessionsController < ApplicationController
  include WorkspaceScoped
  include ChatStreaming

  CHAT_PURPOSE = "brief".freeze
  BRIEF_BLOCK = /<brief>(.*?)<\/brief>/m

  before_action :require_admin!
  before_action :require_workshop!
  before_action :set_task

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end

  def extract_and_save_results(text)
    text.to_s.scan(BRIEF_BLOCK).each do |(body)|
      content = body.to_s.strip
      next if content.blank?
      @task.briefs.create!(
        workspace: current_workspace,
        chat_session: @chat_session,
        version: Brief.next_version_for(@task),
        content: content,
        status: "draft"
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[BriefChat] Brief extraction failed: #{e.message}")
  end

  def build_initial_prompt
    project = @task.project
    context = project.context_info.presence || "(no project context provided)"
    features = project.features_summary.presence || "(no features summary available yet)"
    ticket_section = if @task.external_reference.present?
      "Existing Jira ticket #{@task.external_reference}: #{ticket_title}\n\nDescription:\n#{@task.description.presence || '(none)'}"
    else
      "New idea (not yet in Jira): #{@task.name}\n\n#{@task.description.presence || '(no detail provided yet)'}"
    end
    comments_section = build_comments_section(@task)
    attachments_section = build_attachments_section(@task)

    <<~PROMPT
      # Role

      You are an experienced, skeptical Product Owner. Your job is to turn an idea
      into a sharp, concise BRIEF. You care about USER VALUE and shipping the right
      thing, not gold-plating. The codebase in your working directory is the app
      this project belongs to.

      # Project context (set by the team — read this first)

      #{context}

      # Current features & architecture (auto-summarised from the codebase)

      #{features}

      # The idea to brief

      #{ticket_section}
      #{comments_section}#{attachments_section}

      # How you must operate

      1. Investigate the codebase quietly (read CLAUDE.md, list app/, read the few
         most relevant files) so your suggestions fit what already exists. Don't
         narrate this.
      2. Act like a PO in conversation: ask focused questions to pin down the real
         user value and scope. Propose the option you think is best given the
         existing app, and what could make it genuinely better for users.
      3. CHALLENGE the business logic ONLY when it makes sense — when a requirement
         is unclear, conflicts with the existing app, adds little value, or a
         simpler/stronger option exists. Do NOT challenge for the sake of it; if the
         idea is sound, say so and move on.
      4. Keep the conversation tight. When you have enough, produce the brief.

      # The brief

      When ready, output exactly ONE `<brief>` block. The brief captures the WHOLE
      concept and describes the feature, but is CONCISE — no padding, no restating
      obvious context, no implementation detail. Aim for something a developer and a
      stakeholder can both read in under a minute.

      <brief>
      (The concise brief: the problem/value, who it's for, what we'll build, and the
      acceptance at a high level.)
      </brief>

      Each new `<brief>` block becomes a new saved version; earlier versions stay
      available. Revise into a new block when the user asks for changes.

      # Start now

      Investigate quietly, then open the conversation with your first PO questions
      (or, if the idea is already clear, a short take plus a first `<brief>` draft).
    PROMPT
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/brief_chat_sessions_controller_test.rb`
Expected: PASS (1 run, 0 failures).

- [ ] **Step 7: Run the existing chat tests to confirm no regression**

Run: `bin/rails test test/controllers/breakdown_chat_sessions_controller_test.rb test/models/chat_session_test.rb 2>/dev/null; bin/rails test test/models`
Expected: existing chat/model tests still pass (the PURPOSES change is additive).

- [ ] **Step 8: Commit**

```bash
git add app/controllers/brief_chat_sessions_controller.rb app/models/chat_session.rb config/routes.rb test/controllers/brief_chat_sessions_controller_test.rb
git commit -m "feat: BriefChatSessionsController — skeptical-PO brief conversation"
```

---

## Task 7: BriefCommitsController (commit a brief to Jira)

**Files:**
- Create: `app/controllers/brief_commits_controller.rb`
- Modify: `config/routes.rb` (brief commit route)
- Test: `test/controllers/brief_commits_controller_test.rb`

**Interfaces:**
- Consumes: `JiraWriter#commit_brief` (Task 4); `Brief#mark_briefed!` (Task 2); admin + workshop gate.
- Produces:
  - `POST /jira_tasks/:jira_task_id/briefs/:id/commit` → on `ok`, calls `brief.mark_briefed!`, redirects back with a success notice (issue key/url); on failure, redirects back with an alert and does NOT mark briefed.

- [ ] **Step 1: Add the route**

In `config/routes.rb`, change the briefs resource added in Task 6 to add a member commit:

```ruby
    resources :briefs, only: [:index] do
      member { post :commit }
    end
```

- [ ] **Step 2: Write the failing test**

```ruby
require "test_helper"

class BriefCommitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true, jira_ai_actions_field_id: "customfield_10050")
    @project = @workspace.projects.create!(name: "BCM", color: "#333333",
      external_type: "jira", external_reference: "BCM")
    @task = @project.tasks.create!(name: "BCM-1 Thing", external_type: "jira", external_reference: "BCM-1")
    @brief = Brief.create!(task: @task, workspace: @workspace, version: 1, content: "concept")
    sign_in_as(users(:one)) # admin
  end

  def stub_writer(result)
    orig = JiraWriter.instance_method(:commit_brief)
    JiraWriter.define_method(:commit_brief) { |_b| result }
    yield
  ensure
    JiraWriter.define_method(:commit_brief, orig)
  end

  test "successful commit marks the brief briefed" do
    stub_writer({ ok: true, key: "BCM-1", url: "u" }) do
      post commit_jira_task_brief_path(@task, @brief)
    end
    assert_equal "briefed", @brief.reload.status
    assert_redirected_to(/workshop|jira_tasks/)
  end

  test "failed commit does NOT mark briefed and shows the error" do
    stub_writer({ ok: false, error: "403 Forbidden" }) do
      post commit_jira_task_brief_path(@task, @brief)
    end
    assert_equal "draft", @brief.reload.status
    follow_redirect!
    assert_match "403", response.body
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/controllers/brief_commits_controller_test.rb`
Expected: FAIL — route/controller missing.

- [ ] **Step 4: Implement the controller**

```ruby
# Commits a specific Brief version back to Jira (create-or-update + set the
# "AI actions" field to "Briefed"). Only marks the brief briefed when the Jira
# write actually succeeds — a failure surfaces an alert and leaves the brief a
# draft (no silent success).
class BriefCommitsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :require_workshop!

  def commit
    task = Task.where(project: current_workspace.projects).find(params[:jira_task_id])
    brief = task.briefs.find(params[:id])

    result = JiraWriter.new(workspace: current_workspace).commit_brief(brief)

    if result[:ok]
      brief.mark_briefed!
      redirect_to workshop_brief_path(task), notice: "Briefed in Jira: #{result[:key]}."
    else
      redirect_to workshop_brief_path(task), alert: "Couldn't write to Jira: #{result[:error]}"
    end
  end

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end
end
```

(Note: `workshop_brief_path` is defined in Task 8. If implementing Task 7 before Task 8, temporarily redirect to `jira_tasks_path` and switch to `workshop_brief_path(task)` once Task 8's routes exist. The test regex `/workshop|jira_tasks/` accepts either.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/brief_commits_controller_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/brief_commits_controller.rb config/routes.rb test/controllers/brief_commits_controller_test.rb
git commit -m "feat: commit a brief version to Jira and mark it Briefed"
```

---

## Task 8: WorkshopController + views (tab, idea picker, pipeline page)

**Files:**
- Create: `app/controllers/workshop_controller.rb`
- Create: `app/views/workshop/index.html.erb` (landing: two paths)
- Create: `app/views/workshop/new_idea.html.erb` (Step 1 — new idea form / existing-task picker)
- Create: `app/views/workshop/brief.html.erb` (Steps 2–4 — chat + brief versions + commit)
- Modify: `config/routes.rb` (workshop routes)
- Modify: `app/views/layouts/application.html.erb` (sidebar item)
- Modify: `app/models/project.rb` (design-sprint task scope)
- Test: `test/controllers/workshop_controller_test.rb`

**Interfaces:**
- Consumes: `workshop_enabled` gate, `Project` design-sprint helper, `Task#briefs`, the brief chat route (Task 6), the commit route (Task 7).
- Produces routes/paths:
  - `GET /workshop` → `workshop#index` (`workshop_path`).
  - `GET /workshop/new_idea?project_id=` → `workshop#new_idea` (`new_idea_workshop_path`); lists the project's design-sprint un-briefed tasks + a new-idea form.
  - `POST /workshop/start` → `workshop#start` (`start_workshop_path`); creates-or-finds the Task (new idea → local Task; existing → the chosen task) and redirects to the brief page.
  - `GET /workshop/tasks/:id/brief` → `workshop#brief` (`workshop_brief_path(task)`); the pipeline page for one task.
  - `Project#design_sprint_tasks` → tasks whose `sprint_name` matches /design/i, not yet briefed.

- [ ] **Step 1: Add the design-sprint scope to Project**

In `app/models/project.rb`, add:

```ruby
  # Tasks in a "design" sprint (sprint name contains "design") that haven't been
  # briefed yet — the candidates for the Idea → Brief pipeline.
  def design_sprint_tasks
    tasks.jira_synced
         .where("LOWER(sprint_name) LIKE ?", "%design%")
         .order(:name)
  end
```

- [ ] **Step 2: Add the routes**

In `config/routes.rb`, add (top-level, near the reports/jira section):

```ruby
  get  "workshop",            to: "workshop#index",    as: :workshop
  get  "workshop/new_idea",   to: "workshop#new_idea", as: :new_idea_workshop
  post "workshop/start",      to: "workshop#start",    as: :start_workshop
  get  "workshop/tasks/:id/brief", to: "workshop#brief", as: :workshop_brief
```

- [ ] **Step 3: Write the failing test**

```ruby
require "test_helper"

class WorkshopControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @project = @workspace.projects.create!(name: "WS", color: "#444444",
      external_type: "jira", external_reference: "WS")
    @design = @project.tasks.create!(name: "WS-1 Design task", external_type: "jira",
      external_reference: "WS-1", sprint_name: "Design Sprint 4")
  end

  test "workshop hidden when toggle off" do
    @workspace.update!(workshop_enabled: false)
    sign_in_as(users(:one))
    get workshop_path
    assert_redirected_to root_path
  end

  test "admin sees workshop and the design-sprint task when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get workshop_path
    assert_response :success
    get new_idea_workshop_path(project_id: @project.id)
    assert_response :success
    assert_match "WS-1 Design task", response.body
  end

  test "employee is blocked even when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:two)) # non-admin
    get workshop_path
    assert_redirected_to root_path
  end

  test "start with a new idea creates a local task and redirects to brief" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    assert_difference -> { @project.tasks.count }, 1 do
      post start_workshop_path, params: { project_id: @project.id, mode: "new",
        title: "Fresh idea", body: "do a thing" }
    end
    task = @project.tasks.order(:created_at).last
    assert_nil task.external_reference
    assert_redirected_to workshop_brief_path(task)
  end

  test "start with an existing task redirects to its brief" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    post start_workshop_path, params: { project_id: @project.id, mode: "existing", task_id: @design.id }
    assert_redirected_to workshop_brief_path(@design)
  end

  test "sidebar shows Workshop for admin when enabled" do
    @workspace.update!(workshop_enabled: true)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", workshop_path
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bin/rails test test/controllers/workshop_controller_test.rb`
Expected: FAIL — controller/routes/views missing.

- [ ] **Step 5: Implement the controller**

```ruby
class WorkshopController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :require_workshop!

  def index
    @projects = current_workspace.projects.where(archived: false).order(:name)
    @project = @projects.find_by(id: params[:project_id]) || @projects.first
  end

  def new_idea
    @project = current_workspace.projects.find(params[:project_id])
    @design_tasks = @project.design_sprint_tasks.reject { |t| t.briefs.briefed.exists? }
  end

  def start
    project = current_workspace.projects.find(params[:project_id])

    task =
      if params[:mode] == "existing"
        project.tasks.find(params[:task_id])
      else
        name = params[:title].presence || "Untitled idea"
        project.tasks.create!(name: name, description: params[:body])
      end

    redirect_to workshop_brief_path(task)
  end

  def brief
    @task = Task.where(project: current_workspace.projects).find(params[:id])
    @briefs = @task.briefs.newest_first
  end

  private

  def require_workshop!
    redirect_to root_path unless current_workspace&.workshop_enabled?
  end
end
```

- [ ] **Step 6: Implement the views**

`app/views/workshop/index.html.erb` — landing with the two paths and a project selector:

```erb
<div class="m3-page">
  <h1 class="m3-page-title">Workshop</h1>
  <p class="m3-page-subtitle">Turn ideas into briefs, and briefs into tasks.</p>

  <%= form_with url: new_idea_workshop_path, method: :get, class: "m3-inline-form" do %>
    <%= label_tag :project_id, "Project" %>
    <%= select_tag :project_id,
          options_from_collection_for_select(@projects, :id, :name, @project&.id),
          class: "m3-select" %>
    <%= submit_tag "Idea → Brief", class: "m3-btn m3-btn-primary" %>
  <% end %>

  <div class="m3-card-grid">
    <div class="m3-card">
      <h2>Idea → Brief</h2>
      <p>Pick an existing design-sprint task or start a new idea, then brief it with the AI Product Owner.</p>
    </div>
    <div class="m3-card">
      <h2>Brief → Task</h2>
      <p>Estimate and break a briefed task into vertical slices, then push the spec to Jira.</p>
    </div>
  </div>
</div>
```

`app/views/workshop/new_idea.html.erb` — Step 1:

```erb
<div class="m3-page">
  <h1 class="m3-page-title">Idea → Brief — <%= @project.name %></h1>

  <section class="m3-card">
    <h2>Existing design-sprint task</h2>
    <% if @design_tasks.any? %>
      <ul class="m3-list">
        <% @design_tasks.each do |t| %>
          <li>
            <%= button_to t.name, start_workshop_path,
                  params: { project_id: @project.id, mode: "existing", task_id: t.id },
                  class: "m3-btn m3-btn-link" %>
          </li>
        <% end %>
      </ul>
    <% else %>
      <p class="m3-empty">No un-briefed tasks in a design sprint.</p>
    <% end %>
  </section>

  <section class="m3-card">
    <h2>New idea</h2>
    <%= form_with url: start_workshop_path, method: :post, class: "m3-form" do %>
      <%= hidden_field_tag :project_id, @project.id %>
      <%= hidden_field_tag :mode, "new" %>
      <div class="m3-field">
        <%= label_tag :title, "Title" %>
        <%= text_field_tag :title, nil, class: "m3-input", required: true %>
      </div>
      <div class="m3-field">
        <%= label_tag :body, "Describe the idea" %>
        <%= text_area_tag :body, nil, rows: 6, class: "m3-input" %>
      </div>
      <%= submit_tag "Start briefing", class: "m3-btn m3-btn-primary" %>
    <% end %>
  </section>
</div>
```

`app/views/workshop/brief.html.erb` — Steps 2–4. Reuse the existing chat panel partial for the conversation and list brief versions with a commit button:

```erb
<div class="m3-page" data-controller="task-chat"
     data-task-chat-create-url-value="<%= jira_task_brief_chat_session_path(@task) %>"
     data-task-chat-message-url-value="<%= message_jira_task_brief_chat_session_path(@task) %>"
     data-task-chat-show-url-value="<%= jira_task_brief_chat_session_path(@task) %>">
  <h1 class="m3-page-title">
    Brief — <%= @task.external_reference.presence || "New idea" %>: <%= @task.name %>
  </h1>

  <div class="m3-two-col">
    <section class="m3-card">
      <h2>Brief versions</h2>
      <% if @briefs.any? %>
        <% @briefs.each do |b| %>
          <article class="m3-brief-version">
            <header>
              <strong>v<%= b.version %></strong>
              <span class="m3-badge"><%= b.status %></span>
            </header>
            <pre class="m3-readonly"><%= b.content %></pre>
            <% if b.status == "draft" %>
              <%= button_to "Brief & mark Briefed", commit_jira_task_brief_path(@task, b),
                    class: "m3-btn m3-btn-primary",
                    data: { turbo_confirm: "Write this brief to Jira and mark it Briefed?" } %>
            <% end %>
          </article>
        <% end %>
      <% else %>
        <p class="m3-empty">No brief yet — talk it through with the AI on the right.</p>
      <% end %>
    </section>

    <section class="m3-card">
      <h2>AI Product Owner</h2>
      <%= render "jira_tasks/chat_panel" %>
    </section>
  </div>
</div>
```

(Open `app/views/jira_tasks/_chat_panel.html.erb` and `app/javascript/controllers/task_chat_controller.js` first to confirm the exact `data-*` value names and partial locals the controller expects; mirror them. If the Stimulus controller hard-codes the refine/breakdown URLs rather than reading `data-*` values, add small value-attributes or pass the URLs the way the existing breakdown page does — match whatever pattern `jira_tasks/show.html.erb` uses to wire the breakdown chat.)

- [ ] **Step 7: Add the sidebar item**

In `app/views/layouts/application.html.erb`, in the admin section (next to the Clients toggle pattern), add:

```erb
<% if current_workspace.workshop_enabled? %>
  <%= link_to workshop_path, class: "m3-nav-item #{'active' if current_page?(workshop_path)}" do %>
    <span class="m3-nav-label">Workshop</span>
  <% end %>
<% end %>
```

(Match the exact icon/markup of the neighbouring admin nav items — open the file and copy a sibling link's structure, e.g. the Projects or Clients link.)

- [ ] **Step 8: Run tests to verify they pass**

Run: `bin/rails test test/controllers/workshop_controller_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 9: Build CSS/assets and smoke-check routes**

Run: `bin/rails runner 'puts Rails.application.routes.url_helpers.workshop_path' && bin/rails tailwindcss:build`
Expected: prints `/workshop`; Tailwind build succeeds.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/workshop_controller.rb app/views/workshop config/routes.rb app/views/layouts/application.html.erb app/models/project.rb test/controllers/workshop_controller_test.rb
git commit -m "feat: Workshop tab — landing, idea picker, brief pipeline page"
```

---

## Task 9: ProjectFeaturesScanJob (daily codebase scan)

**Files:**
- Create: `app/jobs/project_features_scan_job.rb`
- Modify: `config/recurring.yml` (schedule)
- Test: `test/jobs/project_features_scan_job_test.rb`

**Interfaces:**
- Consumes: `ClaudeCliService#start_session` (returns `{session_id:, response:}`); `Project#features_summary`; the PR-reviewer failure-marker idea.
- Produces:
  - `ProjectFeaturesScanJob#perform` — for each workspace with `workshop_enabled`, for each Jira-connected project, run a scan and update `features_summary` + `features_summary_updated_at`. A failed/empty/auth-error scan PRESERVES the prior value (no blanking).
  - Constants: `CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))`; reuse `CLI_FAILURE_MARKERS` semantics.
  - `#scan_summary(project)` → String summary or nil on failure.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class ProjectFeaturesScanJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = @workspace.projects.create!(name: "FS", color: "#555555",
      external_type: "jira", external_reference: "FS")
  end

  def with_ai(response)
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| { session_id: "s", response: response } }
    yield
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  test "a good scan stores the summary" do
    # Skip the git pull in tests.
    ProjectFeaturesScanJob.any_instance_stubs_pull = true if false # (no AnyInstance; see Step 3)
    job = ProjectFeaturesScanJob.new
    def job.pull_latest!; true; end
    with_ai("This app does X, Y, Z. Architecture: Rails monolith with ...") do
      job.perform
    end
    assert_match "Architecture", @project.reload.features_summary
    assert_not_nil @project.features_summary_updated_at
  end

  test "an auth-error response preserves the previous summary" do
    @project.update!(features_summary: "PREVIOUS", features_summary_updated_at: 1.day.ago)
    job = ProjectFeaturesScanJob.new
    def job.pull_latest!; true; end
    with_ai("API Error: 401 Invalid authentication credentials") do
      job.perform
    end
    assert_equal "PREVIOUS", @project.reload.features_summary
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/project_features_scan_job_test.rb`
Expected: FAIL — `NameError: uninitialized constant ProjectFeaturesScanJob`.

- [ ] **Step 3: Implement the job**

```ruby
# Daily: pull the latest master of the elvium checkout, then ask the claude CLI
# to summarise the current features + architecture, storing it per Jira-connected
# project in workspaces where Workshop is enabled. The summary feeds the brief
# conversation. A failed git pull, a CLI error, an auth/quota error printed as
# text, or an empty result PRESERVES the previous summary — it never blanks it.
class ProjectFeaturesScanJob < ApplicationJob
  queue_as :default

  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium")).freeze
  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def perform
    return unless pull_latest!

    Workspace.where(workshop_enabled: true).find_each do |workspace|
      workspace.projects.where(external_type: "jira").find_each do |project|
        summary = scan_summary(project)
        next if summary.blank? # preserve prior on failure
        project.update_columns(features_summary: summary, features_summary_updated_at: Time.current)
      end
    end
  end

  private

  def pull_latest!
    out = `cd #{CODEBASE_PATH.shellescape} && git pull --ff-only 2>&1`
    unless $?.success?
      Rails.logger.warn("[FeaturesScan] git pull failed: #{out}")
      return false
    end
    true
  rescue StandardError => e
    Rails.logger.warn("[FeaturesScan] git pull error: #{e.message}")
    false
  end

  def scan_summary(project)
    response = ClaudeCliService.new(codebase_path: CODEBASE_PATH)
                               .start_session(prompt: prompt_for(project))[:response].to_s
    return nil if response.strip.length < 40 || response.match?(CLI_FAILURE_MARKERS)
    response.strip
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[FeaturesScan] claude error for #{project.name}: #{e.message}")
    nil
  end

  def prompt_for(project)
    <<~PROMPT
      Summarise the CURRENT features and main architecture of the application in this
      working directory, for the project "#{project.name}". Read CLAUDE.md, the routes,
      and the main app/ directories. Output a concise plain-text summary (no preamble):
      a bulleted list of the main features the app already has, plus 2–4 sentences on
      the overall architecture (frameworks, main models, how the pieces fit). This is
      reference material for a product owner briefing new work — keep it factual and
      tight, no more than ~400 words.
    PROMPT
  end
end
```

Add `require "shellwords"` at the top if not already loaded (Rails autoloads it; `.shellescape` is available).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/jobs/project_features_scan_job_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Schedule the job**

In `config/recurring.yml`, add (Warsaw TZ, 05:00 daily):

```yaml
  project_features_scan:
    class: ProjectFeaturesScanJob
    schedule: "0 5 * * *"
```

- [ ] **Step 6: Verify the schedule loads**

Run: `bin/rails runner 'puts YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "project_features_scan", "schedule") || YAML.load_file(Rails.root.join("config/recurring.yml")).dig("project_features_scan", "schedule")'`
Expected: prints `0 5 * * *` (the exact key nesting matches the existing entries — mirror how `pr_review_check` is nested in the file).

- [ ] **Step 7: Commit**

```bash
git add app/jobs/project_features_scan_job.rb config/recurring.yml test/jobs/project_features_scan_job_test.rb
git commit -m "feat: daily ProjectFeaturesScanJob fills per-project features summary"
```

---

## Task 10: Brief → Task relocation + "Update Jira" button

**Files:**
- Modify: `app/controllers/task_breakdowns_controller.rb` (add `update_jira`)
- Modify: `config/routes.rb` (breakdown `update_jira` member)
- Modify: `app/views/jira_tasks/show.html.erb` (Update-Jira button on the breakdown panel) OR the workshop brief page link to breakdown
- Modify: `app/services/jira_writer.rb` (add `#commit_breakdown`)
- Test: `test/controllers/task_breakdowns_update_jira_test.rb`, extend `test/services/jira_writer_test.rb`

**Interfaces:**
- Consumes: `Task#latest_breakdown` (existing), `JiraWriter` (Task 4).
- Produces:
  - `JiraWriter#commit_breakdown(task)` → reads `task.latest_breakdown` (JSON), formats description + acceptance criteria into text, calls `update_issue_description`, then `add_ai_action` with value `"Added specification and branch"`. Returns `{ ok:, error: }`.
  - `POST /jira_tasks/:id/breakdown/update_jira` → `task_breakdowns#update_jira` (`update_jira_jira_task_path` or nested name to match existing breakdown routing). On ok → notice; on failure → alert. Admin + workshop gate.

- [ ] **Step 1: Add commit_breakdown to JiraWriter (test first)**

Add to `test/services/jira_writer_test.rb`:

```ruby
  test "commit_breakdown updates description and sets the spec AI action" do
    task = @project.tasks.create!(name: "JW-9 Existing", external_type: "jira", external_reference: "JW-9")
    task.task_drafts.create!(source: TaskDraft::BREAKDOWN_SOURCE,
      content: { needs_breakdown: false, total_points: 3, strategy: "small", subtasks: [] }.to_json)
    c = fake_client
    res = JiraWriter.new(workspace: @workspace, client: c).commit_breakdown(task)
    assert res[:ok], res.inspect
    assert_equal 1, c.calls[:update]
    assert_equal "Added specification and branch", c.calls[:action][:value]
  end
```

Run: `bin/rails test test/services/jira_writer_test.rb` → FAIL (`commit_breakdown` undefined).

Add to `app/services/jira_writer.rb`:

```ruby
  SPEC_VALUE = "Added specification and branch".freeze

  def commit_breakdown(task)
    return { ok: false, error: "Task is not linked to Jira" } if task.external_reference.blank?
    breakdown = task.latest_breakdown
    return { ok: false, error: "No breakdown to push" } if breakdown.blank?

    text = format_breakdown(breakdown.content)
    res = @client.update_issue_description(issue_key: task.external_reference, description_text: text)
    return res unless res[:ok]

    field_id = ai_actions_field_id
    return { ok: false, error: "Couldn't find the '#{AI_ACTION_FIELD_NAME}' field in Jira" } if field_id.blank?

    action = @client.add_ai_action(issue_key: task.external_reference, field_id: field_id, value: SPEC_VALUE)
    action[:ok] ? { ok: true, key: task.external_reference } : { ok: false, error: action[:error] }
  end

  private

  def format_breakdown(json)
    data = JSON.parse(json) rescue {}
    lines = []
    lines << "Strategy: #{data['strategy']}" if data["strategy"].present?
    (data["subtasks"] || []).each do |st|
      lines << "• #{st['title']} (#{st['points']} pts): #{st['description']}"
      Array(st["acceptance_criteria"]).each { |ac| lines << "    - #{ac}" }
    end
    lines << "Total points: #{data['total_points']}" if data["total_points"].present?
    lines.join("\n")
  end
```

Run: `bin/rails test test/services/jira_writer_test.rb` → PASS.

- [ ] **Step 2: Add the route**

In `config/routes.rb`, inside `resources :jira_tasks`, add a member action mirroring the existing `breakdown` GET:

```ruby
    post :breakdown_update_jira, to: "task_breakdowns#update_jira"
```

(Use `on: :member`-style nesting consistent with how `get :breakdown` is declared; check the surrounding block and match it.)

- [ ] **Step 3: Write the controller test**

```ruby
require "test_helper"

class TaskBreakdownsUpdateJiraTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true, jira_ai_actions_field_id: "customfield_10050")
    @project = @workspace.projects.create!(name: "UJ", color: "#666666",
      external_type: "jira", external_reference: "UJ")
    @task = @project.tasks.create!(name: "UJ-1 Thing", external_type: "jira", external_reference: "UJ-1")
    @task.task_drafts.create!(source: TaskDraft::BREAKDOWN_SOURCE,
      content: { needs_breakdown: false, total_points: 2, subtasks: [] }.to_json)
    sign_in_as(users(:one))
  end

  def stub_writer(result)
    orig = JiraWriter.instance_method(:commit_breakdown)
    JiraWriter.define_method(:commit_breakdown) { |_t| result }
    yield
  ensure
    JiraWriter.define_method(:commit_breakdown, orig)
  end

  test "update_jira success shows a notice" do
    stub_writer({ ok: true, key: "UJ-1" }) do
      post breakdown_update_jira_jira_task_path(@task)
    end
    assert_response :redirect
    follow_redirect!
    assert_match "UJ-1", response.body
  end

  test "update_jira failure shows an alert" do
    stub_writer({ ok: false, error: "403" }) do
      post breakdown_update_jira_jira_task_path(@task)
    end
    follow_redirect!
    assert_match "403", response.body
  end
end
```

(Confirm the generated path helper name with `bin/rails routes -g breakdown_update_jira`; adjust the helper in the test to match.)

- [ ] **Step 4: Run test to verify it fails**

Run: `bin/rails test test/controllers/task_breakdowns_update_jira_test.rb`
Expected: FAIL — action missing.

- [ ] **Step 5: Implement the action**

In `app/controllers/task_breakdowns_controller.rb`, add:

```ruby
  def update_jira
    return head(:forbidden) unless current_workspace&.workshop_enabled? && current_user_admin?
    task = Task.where(project: current_workspace.projects).find(params[:jira_task_id] || params[:id])
    result = JiraWriter.new(workspace: current_workspace).commit_breakdown(task)
    if result[:ok]
      redirect_back fallback_location: breakdown_jira_task_path(task), notice: "Spec pushed to Jira: #{result[:key]}."
    else
      redirect_back fallback_location: breakdown_jira_task_path(task), alert: "Couldn't write to Jira: #{result[:error]}"
    end
  end
```

(Use the existing admin check used elsewhere in this controller / `WorkspaceScoped` — match the helper name actually available, e.g. `require_admin!` as a `before_action` limited to `:update_jira`, instead of an inline check, if that's the established pattern. Confirm the breakdown show path helper name via `bin/rails routes -g breakdown`.)

- [ ] **Step 6: Add the button to the breakdown view**

In `app/views/jira_tasks/show.html.erb`, near the breakdown version dropdown (around the breakdown panel), add — only when Workshop is on and a breakdown exists:

```erb
<% if current_workspace.workshop_enabled? && @task.latest_breakdown.present? %>
  <%= button_to "Update Jira", breakdown_update_jira_jira_task_path(@task),
        class: "m3-btn m3-btn-secondary",
        data: { turbo_confirm: "Push the latest breakdown to Jira and mark the spec action?" } %>
<% end %>
```

(Open the file and place it beside the existing breakdown controls, matching their wrapper markup.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `bin/rails test test/controllers/task_breakdowns_update_jira_test.rb test/services/jira_writer_test.rb`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/services/jira_writer.rb app/controllers/task_breakdowns_controller.rb app/views/jira_tasks/show.html.erb config/routes.rb test/controllers/task_breakdowns_update_jira_test.rb test/services/jira_writer_test.rb
git commit -m "feat: Update Jira button pushes the breakdown spec to the issue"
```

---

## Task 11: Full-suite regression + manual smoke

**Files:** none (verification task).

- [ ] **Step 1: Run the full test suite**

Run: `bin/rails test`
Expected: All new tests pass. Pre-existing failures unrelated to this work (holiday overlap, `claude_cli --add-dir` ×3, `jira_sync fetch_all_comments`) may remain — confirm the count matches the pre-change baseline and that NONE of the new failures touch Workshop/Brief/JiraWriter files. If a new failure appears, fix it before proceeding.

- [ ] **Step 2: Build assets**

Run: `bin/rails tailwindcss:build`
Expected: success.

- [ ] **Step 3: Manual smoke (local, dev server)**

Start the app, sign in as an admin, enable Workshop in workspace settings, open `/workshop`, run the new-idea path through a brief, and confirm: a draft `Brief` appears with a version; the "Brief & mark Briefed" button is present. (Do NOT click commit unless pointed at a real Jira sandbox — it writes to Jira.) Document anything that needs the real Jira field ID.

- [ ] **Step 4: Commit any fixups**

```bash
git add -A
git commit -m "chore: workshop regression fixups"  # only if there were changes
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Workshop tab, admin-only, `workshop_enabled` toggle → Tasks 5, 8.
- Idea→Brief Step 1 (existing design-sprint task / new idea) → Task 8 (`new_idea`, `start`, `design_sprint_tasks`).
- Step 2 PO conversation fed by `context_info` + `features_summary` → Task 6.
- Step 3 versioned Brief from `<brief>` blocks → Tasks 2, 6.
- Step 4 commit: create (new) / update (existing) + set "Briefed", no silent success → Tasks 3, 4, 7.
- Two project fields (auto `features_summary`, manual `context_info`) → Tasks 1, 5, 9.
- Daily scan, pull master first, preserve-on-failure → Task 9.
- Brief→Task relocation + Update-Jira button → Task 10.
- Jira-write capability (first in the app) → Tasks 3, 4.
- Error handling (checked results, no silent success, preserve summary, missing-field message) → Tasks 3, 4, 7, 9, 10.
- Tests across model/service/job/controller → every task.

**Placeholder scan:** No TBD/TODO. Every code step shows real code. A few steps say "open the file and match the existing markup/helper name" — these are deliberate fidelity instructions for view/route naming that depends on exact existing strings the implementer must read; they are paired with concrete code and exact run commands, not vague directives.

**Type consistency:** `JiraClient` write methods return `{ ok:, ... }`; `JiraWriter#commit_brief`/`#commit_breakdown` return `{ ok:, key:, url:/error: }`; controllers check `result[:ok]`. `Brief.next_version_for(task)` / `mark_briefed!` / `Task#latest_brief` used consistently across Tasks 2, 6, 7. `purpose: "brief"` added to `ChatSession::PURPOSES` (Task 6) before the brief controller uses it. `commit_breakdown` uses the existing `TaskDraft::BREAKDOWN_SOURCE` and `Task#latest_breakdown`.

**Known fidelity risks flagged for the implementer (not blockers):** exact `m3-*` class names and the `task_chat` Stimulus `data-*` wiring must be copied from the live views/JS (Tasks 5, 8); the breakdown route helper name must be confirmed via `bin/rails routes` (Task 10). The plan instructs verification at each.
