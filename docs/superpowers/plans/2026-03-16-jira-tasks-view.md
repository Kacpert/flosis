# Jira Tasks View Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Jira Tasks page with Kanban/list views, board/sprint filters, and task detail modal.

**Architecture:** Extend the existing Jira sync to fetch boards, sprints, columns, and richer issue data into new models. Build a new `JiraTasksController` that serves the page with Turbo Frames for dynamic filtering. Stimulus controllers handle filter changes, view toggling, manual refresh, and the detail modal.

**Tech Stack:** Rails 8.1, Minitest, Stimulus, Turbo Frames/Streams, Tailwind CSS + DaisyUI (m3-* design system), WebMock for API stubs.

**Spec:** `docs/superpowers/specs/2026-03-16-jira-tasks-view-design.md`

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `db/migrate/TIMESTAMP_create_jira_board_tables.rb` | Migration for jira_boards, jira_sprints, jira_board_columns, jira_board_column_statuses |
| `db/migrate/TIMESTAMP_add_detail_fields_to_tasks.rb` | Add description, priority, issue_type, labels, reporter_email, sprint_name, sprint_id, time_estimate_seconds to tasks |
| `app/models/jira_board.rb` | JiraBoard model |
| `app/models/jira_sprint.rb` | JiraSprint model |
| `app/models/jira_board_column.rb` | JiraBoardColumn model |
| `app/models/jira_board_column_status.rb` | JiraBoardColumnStatus model |
| `app/controllers/jira_tasks_controller.rb` | Controller for the Jira Tasks page |
| `app/views/jira_tasks/index.html.erb` | Main page with filter bar and Turbo Frame |
| `app/views/jira_tasks/_kanban.html.erb` | Kanban board partial |
| `app/views/jira_tasks/_list.html.erb` | List view partial |
| `app/views/jira_tasks/_task_detail.html.erb` | Task detail modal content |
| `app/views/jira_tasks/_empty_state.html.erb` | Empty state partial |
| `app/javascript/controllers/jira_tasks_controller.js` | Stimulus: filter bar, view toggle, refresh |
| `app/javascript/controllers/jira_task_modal_controller.js` | Stimulus: task detail modal |
| `test/models/jira_board_test.rb` | Model tests |
| `test/models/jira_sprint_test.rb` | Model tests |
| `test/models/jira_board_column_test.rb` | Model tests |
| `test/models/jira_board_column_status_test.rb` | Model tests |
| `test/services/jira_client_agile_test.rb` | Tests for new Agile API methods |
| `test/services/jira_sync_service_boards_test.rb` | Tests for board/sprint/column sync |
| `test/controllers/jira_tasks_controller_test.rb` | Controller integration tests |
| `test/fixtures/jira_boards.yml` | Fixture data |
| `test/fixtures/jira_sprints.yml` | Fixture data |
| `test/fixtures/jira_board_columns.yml` | Fixture data |
| `test/fixtures/jira_board_column_statuses.yml` | Fixture data |

### Modified Files
| File | Changes |
|------|---------|
| `app/models/project.rb` | Add `has_many :jira_boards` |
| `app/services/jira_client.rb` | Add `fetch_boards`, `fetch_board_configuration`, `fetch_sprints`, extend `fetch_issues`, add `adf_to_text` |
| `app/services/jira_sync_service.rb` | Add board/sprint/column sync, extend issue sync with new fields |
| `config/routes.rb` | Add `resources :jira_tasks` routes |
| `app/views/layouts/application.html.erb` | Add "Jira Tasks" nav item |
| `test/fixtures/tasks.yml` | Add detail fields to jira_task fixture |
| `test/services/jira_sync_service_test.rb` | Update existing tests for new fields |

---

## Chunk 1: Data Layer (Migrations, Models, Fixtures)

### Task 1: Create jira board tables migration

**Files:**
- Create: `db/migrate/TIMESTAMP_create_jira_board_tables.rb`

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration CreateJiraBoardTables
```

- [ ] **Step 2: Write the migration**

Edit the generated migration file:

```ruby
class CreateJiraBoardTables < ActiveRecord::Migration[8.1]
  def change
    create_table :jira_boards do |t|
      t.references :project, null: false, foreign_key: true
      t.integer :jira_board_id, null: false
      t.string :name, null: false
      t.string :board_type, null: false
      t.timestamps
    end
    add_index :jira_boards, [:project_id, :jira_board_id], unique: true

    create_table :jira_sprints do |t|
      t.references :jira_board, null: false, foreign_key: true
      t.integer :jira_sprint_id, null: false
      t.string :name, null: false
      t.string :state, null: false
      t.datetime :start_date
      t.datetime :end_date
      t.timestamps
    end
    add_index :jira_sprints, [:jira_board_id, :jira_sprint_id], unique: true

    create_table :jira_board_columns do |t|
      t.references :jira_board, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position, null: false
      t.timestamps
    end
    add_index :jira_board_columns, [:jira_board_id, :position], unique: true

    create_table :jira_board_column_statuses do |t|
      t.references :jira_board_column, null: false, foreign_key: true
      t.string :jira_status_name, null: false
      t.string :jira_status_id, null: false
      t.timestamps
    end
    add_index :jira_board_column_statuses, [:jira_board_column_id, :jira_status_id],
              unique: true, name: "idx_board_col_statuses_on_col_and_status"
  end
end
```

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
```

Expected: Migration runs successfully, `db/schema.rb` is updated with 4 new tables.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/*_create_jira_board_tables.rb db/schema.rb
git commit -m "feat: add jira_boards, jira_sprints, jira_board_columns, jira_board_column_statuses tables"
```

### Task 2: Add detail fields to tasks migration

**Files:**
- Create: `db/migrate/TIMESTAMP_add_detail_fields_to_tasks.rb`

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration AddDetailFieldsToTasks
```

- [ ] **Step 2: Write the migration**

```ruby
class AddDetailFieldsToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :description, :text
    add_column :tasks, :priority, :string
    add_column :tasks, :issue_type, :string
    add_column :tasks, :labels, :text
    add_column :tasks, :reporter_email, :string
    add_column :tasks, :sprint_name, :string
    add_column :tasks, :sprint_id, :integer
    add_column :tasks, :time_estimate_seconds, :integer
  end
end
```

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
```

- [ ] **Step 4: Commit**

```bash
git add db/migrate/*_add_detail_fields_to_tasks.rb db/schema.rb
git commit -m "feat: add description, priority, issue_type, labels, reporter_email, sprint fields to tasks"
```

### Task 3: Create models with tests and fixtures

**Files:**
- Create: `app/models/jira_board.rb`
- Create: `app/models/jira_sprint.rb`
- Create: `app/models/jira_board_column.rb`
- Create: `app/models/jira_board_column_status.rb`
- Create: `test/models/jira_board_test.rb`
- Create: `test/models/jira_sprint_test.rb`
- Create: `test/models/jira_board_column_test.rb`
- Create: `test/models/jira_board_column_status_test.rb`
- Create: `test/fixtures/jira_boards.yml`
- Create: `test/fixtures/jira_sprints.yml`
- Create: `test/fixtures/jira_board_columns.yml`
- Create: `test/fixtures/jira_board_column_statuses.yml`
- Modify: `app/models/project.rb:4` — add `has_many :jira_boards`
- Modify: `test/fixtures/tasks.yml` — add detail fields to jira_task

- [ ] **Step 1: Write fixture files**

`test/fixtures/jira_boards.yml`:
```yaml
design_board:
  project: jira_project
  jira_board_id: 101
  name: Design
  board_type: scrum

dev_board:
  project: jira_project
  jira_board_id: 102
  name: DEV board
  board_type: scrum
```

`test/fixtures/jira_sprints.yml`:
```yaml
design_sprint:
  jira_board: design_board
  jira_sprint_id: 569
  name: Design Sprint
  state: active
  start_date: 2026-03-01
  end_date: 2026-03-15

closed_sprint:
  jira_board: design_board
  jira_sprint_id: 33
  name: Old Sprint
  state: closed
  start_date: 2026-02-01
  end_date: 2026-02-28
```

`test/fixtures/jira_board_columns.yml`:
```yaml
todo_column:
  jira_board: design_board
  name: "TO DO (DESIGN)"
  position: 0

in_progress_column:
  jira_board: design_board
  name: "IN PROGRESS (DESIGN)"
  position: 1

done_column:
  jira_board: design_board
  name: "DONE (DESIGN)"
  position: 2
```

`test/fixtures/jira_board_column_statuses.yml`:
```yaml
todo_status:
  jira_board_column: todo_column
  jira_status_name: "To Do"
  jira_status_id: "10001"

in_progress_status:
  jira_board_column: in_progress_column
  jira_status_name: "In Progress"
  jira_status_id: "10002"

done_status:
  jira_board_column: done_column
  jira_status_name: "Done"
  jira_status_id: "10003"
```

- [ ] **Step 2: Update tasks fixture with detail fields**

Update `test/fixtures/tasks.yml` — add fields to `jira_task`:
```yaml
jira_task:
  name: "ELV-1 Existing task"
  project: jira_project
  external_type: jira
  external_reference: ELV-1
  external_url: https://elvium.atlassian.net/browse/ELV-1
  assignee_email: one@example.com
  jira_status_name: In Progress
  description: "This is a test task description"
  priority: High
  issue_type: Story
  labels: '["Feature","HR"]'
  reporter_email: reporter@example.com
  sprint_name: Design Sprint
  sprint_id: 569
  time_estimate_seconds: 3600
```

- [ ] **Step 3: Write model files**

`app/models/jira_board.rb`:
```ruby
class JiraBoard < ApplicationRecord
  belongs_to :project
  has_many :jira_sprints, dependent: :destroy
  has_many :jira_board_columns, -> { order(:position) }, dependent: :destroy

  validates :jira_board_id, presence: true, uniqueness: { scope: :project_id }
  validates :name, presence: true
  validates :board_type, presence: true, inclusion: { in: %w[scrum kanban] }
end
```

`app/models/jira_sprint.rb`:
```ruby
class JiraSprint < ApplicationRecord
  belongs_to :jira_board

  validates :jira_sprint_id, presence: true, uniqueness: { scope: :jira_board_id }
  validates :name, presence: true
  validates :state, presence: true, inclusion: { in: %w[active closed future] }

  scope :active_or_future, -> { where(state: %w[active future]) }
end
```

`app/models/jira_board_column.rb`:
```ruby
class JiraBoardColumn < ApplicationRecord
  belongs_to :jira_board
  has_many :jira_board_column_statuses, dependent: :destroy

  validates :name, presence: true
  validates :position, presence: true, uniqueness: { scope: :jira_board_id }

  def status_names
    jira_board_column_statuses.pluck(:jira_status_name)
  end
end
```

`app/models/jira_board_column_status.rb`:
```ruby
class JiraBoardColumnStatus < ApplicationRecord
  belongs_to :jira_board_column

  validates :jira_status_name, presence: true
  validates :jira_status_id, presence: true, uniqueness: { scope: :jira_board_column_id }
end
```

- [ ] **Step 4: Add association to Project model**

In `app/models/project.rb`, add after line 4 (`has_many :tasks, dependent: :destroy`):
```ruby
  has_many :jira_boards, dependent: :destroy
```

- [ ] **Step 5: Write model tests**

`test/models/jira_board_test.rb`:
```ruby
require "test_helper"

class JiraBoardTest < ActiveSupport::TestCase
  test "belongs to project" do
    board = jira_boards(:design_board)
    assert_equal projects(:jira_project), board.project
  end

  test "has many sprints" do
    board = jira_boards(:design_board)
    assert board.jira_sprints.count >= 1
  end

  test "has many columns ordered by position" do
    board = jira_boards(:design_board)
    positions = board.jira_board_columns.pluck(:position)
    assert_equal positions.sort, positions
  end

  test "validates presence of required fields" do
    board = JiraBoard.new
    assert_not board.valid?
    assert_includes board.errors[:jira_board_id], "can't be blank"
    assert_includes board.errors[:name], "can't be blank"
    assert_includes board.errors[:board_type], "can't be blank"
  end

  test "validates board_type inclusion" do
    board = jira_boards(:design_board)
    board.board_type = "invalid"
    assert_not board.valid?
  end

  test "validates uniqueness of jira_board_id within project" do
    existing = jira_boards(:design_board)
    duplicate = JiraBoard.new(
      project: existing.project,
      jira_board_id: existing.jira_board_id,
      name: "Duplicate",
      board_type: "scrum"
    )
    assert_not duplicate.valid?
  end
end
```

`test/models/jira_sprint_test.rb`:
```ruby
require "test_helper"

class JiraSprintTest < ActiveSupport::TestCase
  test "belongs to jira_board" do
    sprint = jira_sprints(:design_sprint)
    assert_equal jira_boards(:design_board), sprint.jira_board
  end

  test "active_or_future scope excludes closed" do
    board = jira_boards(:design_board)
    sprints = board.jira_sprints.active_or_future
    assert sprints.all? { |s| %w[active future].include?(s.state) }
  end

  test "validates presence of required fields" do
    sprint = JiraSprint.new
    assert_not sprint.valid?
    assert_includes sprint.errors[:jira_sprint_id], "can't be blank"
    assert_includes sprint.errors[:name], "can't be blank"
    assert_includes sprint.errors[:state], "can't be blank"
  end

  test "validates state inclusion" do
    sprint = jira_sprints(:design_sprint)
    sprint.state = "invalid"
    assert_not sprint.valid?
  end
end
```

`test/models/jira_board_column_test.rb`:
```ruby
require "test_helper"

class JiraBoardColumnTest < ActiveSupport::TestCase
  test "belongs to jira_board" do
    column = jira_board_columns(:todo_column)
    assert_equal jira_boards(:design_board), column.jira_board
  end

  test "has many statuses" do
    column = jira_board_columns(:todo_column)
    assert column.jira_board_column_statuses.count >= 1
  end

  test "status_names returns array of status names" do
    column = jira_board_columns(:todo_column)
    assert_includes column.status_names, "To Do"
  end

  test "validates presence of required fields" do
    column = JiraBoardColumn.new
    assert_not column.valid?
    assert_includes column.errors[:name], "can't be blank"
    assert_includes column.errors[:position], "can't be blank"
  end
end
```

`test/models/jira_board_column_status_test.rb`:
```ruby
require "test_helper"

class JiraBoardColumnStatusTest < ActiveSupport::TestCase
  test "belongs to jira_board_column" do
    status = jira_board_column_statuses(:todo_status)
    assert_equal jira_board_columns(:todo_column), status.jira_board_column
  end

  test "validates presence of required fields" do
    status = JiraBoardColumnStatus.new
    assert_not status.valid?
    assert_includes status.errors[:jira_status_name], "can't be blank"
    assert_includes status.errors[:jira_status_id], "can't be blank"
  end
end
```

- [ ] **Step 6: Run model tests**

```bash
bin/rails test test/models/jira_board_test.rb test/models/jira_sprint_test.rb test/models/jira_board_column_test.rb test/models/jira_board_column_status_test.rb
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/models/jira_board.rb app/models/jira_sprint.rb app/models/jira_board_column.rb app/models/jira_board_column_status.rb app/models/project.rb test/models/ test/fixtures/jira_boards.yml test/fixtures/jira_sprints.yml test/fixtures/jira_board_columns.yml test/fixtures/jira_board_column_statuses.yml test/fixtures/tasks.yml
git commit -m "feat: add JiraBoard, JiraSprint, JiraBoardColumn, JiraBoardColumnStatus models with tests"
```

---

## Chunk 2: Jira API Client Extensions

### Task 4: Add Agile API methods to JiraClient

**Files:**
- Modify: `app/services/jira_client.rb`
- Create: `test/services/jira_client_agile_test.rb`

- [ ] **Step 1: Write tests for fetch_boards**

Create `test/services/jira_client_agile_test.rb`:
```ruby
require "test_helper"
require "webmock/minitest"

class JiraClientAgileTest < ActiveSupport::TestCase
  setup do
    @client = JiraClient.new(
      domain: "test.atlassian.net",
      email: "test@example.com",
      api_token: "test-token"
    )
    @agile_url = "https://test.atlassian.net/rest/agile/1.0"
  end

  test "fetch_boards returns boards for a project" do
    stub_request(:get, "#{@agile_url}/board")
      .with(query: hash_including("projectKeyOrId" => "ELV"))
      .to_return(
        status: 200,
        body: {
          values: [
            { id: 101, name: "Design", type: "scrum" },
            { id: 102, name: "DEV board", type: "scrum" }
          ],
          isLast: true
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    boards = @client.fetch_boards("ELV")
    assert_equal 2, boards.length
    assert_equal 101, boards.first[:id]
    assert_equal "Design", boards.first[:name]
    assert_equal "scrum", boards.first[:type]
  end

  test "fetch_boards returns empty array on failure" do
    stub_request(:get, "#{@agile_url}/board")
      .with(query: hash_including("projectKeyOrId" => "ELV"))
      .to_return(status: 500)

    assert_equal [], @client.fetch_boards("ELV")
  end

  test "fetch_board_configuration returns columns with statuses" do
    stub_request(:get, "#{@agile_url}/board/101/configuration")
      .to_return(
        status: 200,
        body: {
          columnConfig: {
            columns: [
              { name: "TO DO (DESIGN)", statuses: [{ id: "10001", self: "https://..." }] },
              { name: "IN PROGRESS (DESIGN)", statuses: [{ id: "10002", self: "https://..." }] },
              { name: "DONE (DESIGN)", statuses: [{ id: "10003", self: "https://..." }] }
            ]
          }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    columns = @client.fetch_board_configuration(101)
    assert_equal 3, columns.length
    assert_equal "TO DO (DESIGN)", columns.first[:name]
    assert_equal [{ id: "10001" }], columns.first[:statuses]
  end

  test "fetch_board_configuration returns empty on failure" do
    stub_request(:get, "#{@agile_url}/board/101/configuration")
      .to_return(status: 404)

    assert_equal [], @client.fetch_board_configuration(101)
  end

  test "fetch_sprints returns sprints for a board" do
    stub_request(:get, "#{@agile_url}/board/101/sprint")
      .with(query: hash_including({}))
      .to_return(
        status: 200,
        body: {
          values: [
            { id: 569, name: "Design Sprint", state: "active", startDate: "2026-03-01T00:00:00.000Z", endDate: "2026-03-15T00:00:00.000Z" },
            { id: 33, name: "Old Sprint", state: "closed", startDate: "2026-02-01T00:00:00.000Z", endDate: "2026-02-28T00:00:00.000Z" }
          ],
          isLast: true
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    sprints = @client.fetch_sprints(101)
    assert_equal 2, sprints.length
    assert_equal 569, sprints.first[:id]
    assert_equal "Design Sprint", sprints.first[:name]
    assert_equal "active", sprints.first[:state]
  end

  test "fetch_sprints handles pagination" do
    stub_request(:get, "#{@agile_url}/board/101/sprint")
      .to_return(
        { status: 200, body: {
          values: [{ id: 1, name: "S1", state: "closed" }],
          isLast: false
        }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: {
          values: [{ id: 2, name: "S2", state: "active" }],
          isLast: true
        }.to_json, headers: { "Content-Type" => "application/json" } }
      )

    sprints = @client.fetch_sprints(101)
    assert_equal 2, sprints.length
  end

  test "fetch_sprints returns empty on failure" do
    stub_request(:get, "#{@agile_url}/board/101/sprint")
      .with(query: hash_including({}))
      .to_return(status: 500)

    assert_equal [], @client.fetch_sprints(101)
  end

  test "adf_to_text extracts text from ADF document" do
    adf = {
      "type" => "doc",
      "content" => [
        { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello world" }] },
        { "type" => "heading", "attrs" => { "level" => 2 }, "content" => [{ "type" => "text", "text" => "Section" }] },
        { "type" => "bulletList", "content" => [
          { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Item 1" }] }] },
          { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Item 2" }] }] }
        ] }
      ]
    }

    text = @client.send(:adf_to_text, adf)
    assert_includes text, "Hello world"
    assert_includes text, "Section"
    assert_includes text, "Item 1"
    assert_includes text, "Item 2"
  end

  test "adf_to_text handles nil" do
    assert_nil @client.send(:adf_to_text, nil)
  end

  test "fetch_issues returns extended fields" do
    stub_request(:post, "https://test.atlassian.net/rest/api/3/search/jql")
      .to_return(
        status: 200,
        body: {
          issues: [
            {
              key: "ELV-42",
              fields: {
                summary: "Fix login page",
                status: { name: "In Progress", statusCategory: { key: "indeterminate" } },
                assignee: { emailAddress: "kacper@example.com" },
                description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "Fix the bug" }] }] },
                priority: { name: "High" },
                issuetype: { name: "Bug" },
                labels: ["urgent", "frontend"],
                reporter: { emailAddress: "reporter@example.com" },
                sprint: { id: 569, name: "Design Sprint" },
                timeoriginalestimate: 7200
              }
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    issues = @client.fetch_issues("ELV")
    issue = issues.first
    assert_equal "Fix the bug", issue[:description]
    assert_equal "High", issue[:priority]
    assert_equal "Bug", issue[:issue_type]
    assert_equal ["urgent", "frontend"], issue[:labels]
    assert_equal "reporter@example.com", issue[:reporter_email]
    assert_equal 569, issue[:sprint_id]
    assert_equal "Design Sprint", issue[:sprint_name]
    assert_equal 7200, issue[:time_estimate_seconds]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bin/rails test test/services/jira_client_agile_test.rb
```

Expected: All tests fail (methods not defined).

- [ ] **Step 3: Implement fetch_boards in JiraClient**

Add to `app/services/jira_client.rb` after `fetch_issues` method (before `private`):

```ruby
  def fetch_boards(project_key)
    return [] unless project_key.match?(PROJECT_KEY_FORMAT)

    results = []
    start_at = 0

    loop do
      data = get("/rest/agile/1.0/board", projectKeyOrId: project_key, startAt: start_at, maxResults: 50)
      return [] unless data

      values = data["values"] || []
      results.concat(values.map { |b| { id: b["id"], name: b["name"], type: b["type"] } })

      break if data["isLast"] != false
      start_at += values.length
    end

    results
  end

  def fetch_board_configuration(board_id)
    data = get("/rest/agile/1.0/board/#{board_id}/configuration")
    return [] unless data

    columns = data.dig("columnConfig", "columns") || []
    columns.map do |col|
      {
        name: col["name"],
        statuses: (col["statuses"] || []).map { |s| { id: s["id"] } }
      }
    end
  end

  def fetch_sprints(board_id)
    results = []
    start_at = 0

    loop do
      data = get("/rest/agile/1.0/board/#{board_id}/sprint", startAt: start_at, maxResults: 50)
      return [] unless data

      values = data["values"] || []
      results.concat(values.map { |s|
        {
          id: s["id"],
          name: s["name"],
          state: s["state"],
          start_date: s["startDate"],
          end_date: s["endDate"]
        }
      })

      break if data["isLast"] != false
      start_at += values.length
    end

    results
  end
```

- [ ] **Step 4: Extend fetch_issues and parse_issue with new fields, add adf_to_text**

In `app/services/jira_client.rb`, update the `fields` array in `fetch_issues`:

```ruby
fields: ["summary", "status", "assignee", "description", "priority", "issuetype", "labels", "reporter", "sprint", "timeoriginalestimate"],
```

Update `parse_issue` to include new fields:

```ruby
  def parse_issue(issue)
    fields = issue["fields"] || {}
    status = fields.dig("status", "statusCategory") || {}

    {
      key: issue["key"],
      summary: fields["summary"],
      status_category: status["key"],
      status_name: fields.dig("status", "name"),
      assignee_email: fields.dig("assignee", "emailAddress"),
      url: "https://#{@domain}/browse/#{issue['key']}",
      description: adf_to_text(fields["description"]),
      priority: fields.dig("priority", "name"),
      issue_type: fields.dig("issuetype", "name"),
      labels: fields["labels"] || [],
      reporter_email: fields.dig("reporter", "emailAddress"),
      sprint_id: fields.dig("sprint", "id"),
      sprint_name: fields.dig("sprint", "name"),
      time_estimate_seconds: fields["timeoriginalestimate"]
    }
  end

  def adf_to_text(node)
    return nil if node.nil?
    return node["text"] if node["type"] == "text"

    content = node["content"]
    return "" unless content.is_a?(Array)

    parts = content.map { |child| adf_to_text(child) }.compact

    case node["type"]
    when "doc"
      parts.join("\n\n")
    when "paragraph", "heading", "blockquote", "codeBlock"
      parts.join
    when "bulletList", "orderedList"
      parts.map { |p| "- #{p}" }.join("\n")
    when "listItem"
      parts.join
    else
      parts.join
    end
  end
```

- [ ] **Step 5: Run all JiraClient tests**

```bash
bin/rails test test/services/jira_client_test.rb test/services/jira_client_agile_test.rb
```

Expected: All tests pass. The existing `fetch_issues` tests may need a minor update if the response stub doesn't include the new fields — they should still pass since `parse_issue` handles nil gracefully.

- [ ] **Step 6: Commit**

```bash
git add app/services/jira_client.rb test/services/jira_client_agile_test.rb
git commit -m "feat: add fetch_boards, fetch_board_configuration, fetch_sprints to JiraClient, extend fetch_issues with detail fields"
```

---

## Chunk 3: Sync Service Extensions

### Task 5: Extend JiraSyncService with board/sprint/column sync

**Files:**
- Modify: `app/services/jira_sync_service.rb`
- Create: `test/services/jira_sync_service_boards_test.rb`
- Modify: `test/services/jira_sync_service_test.rb`

- [ ] **Step 1: Write tests for board sync**

Create `test/services/jira_sync_service_boards_test.rb`:

```ruby
require "test_helper"

class JiraSyncServiceBoardsTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
  end

  def stub_client(boards: [], board_configs: {}, sprints: {}, issues: [])
    mock = Minitest::Mock.new
    mock.expect(:fetch_boards, boards, ["ELV"])
    boards.each do |b|
      config = board_configs[b[:id]] || []
      mock.expect(:fetch_board_configuration, config, [b[:id]])
      sprint_list = sprints[b[:id]] || []
      mock.expect(:fetch_sprints, sprint_list, [b[:id]])
    end
    mock.expect(:fetch_issues, issues, ["ELV"])
    mock
  end

  test "syncs boards from Jira" do
    client = stub_client(
      boards: [{ id: 201, name: "New Board", type: "kanban" }],
      board_configs: { 201 => [{ name: "Todo", statuses: [{ id: "1" }] }] },
      sprints: {}
    )

    JiraSyncService.new(@project, client: client).sync

    board = @project.jira_boards.find_by(jira_board_id: 201)
    assert board.present?
    assert_equal "New Board", board.name
    assert_equal "kanban", board.board_type
  end

  test "updates existing boards" do
    client = stub_client(
      boards: [{ id: 101, name: "Design Renamed", type: "scrum" }],
      board_configs: { 101 => [{ name: "Todo", statuses: [{ id: "1" }] }] },
      sprints: {}
    )

    JiraSyncService.new(@project, client: client).sync

    board = jira_boards(:design_board).reload
    assert_equal "Design Renamed", board.name
  end

  test "syncs board columns and statuses" do
    client = stub_client(
      boards: [{ id: 101, name: "Design", type: "scrum" }],
      board_configs: {
        101 => [
          { name: "TODO", statuses: [{ id: "10001" }, { id: "10004" }] },
          { name: "DONE", statuses: [{ id: "10003" }] }
        ]
      },
      sprints: {}
    )

    JiraSyncService.new(@project, client: client).sync

    board = @project.jira_boards.find_by(jira_board_id: 101)
    assert_equal 2, board.jira_board_columns.count
    todo_col = board.jira_board_columns.find_by(name: "TODO")
    assert_equal 0, todo_col.position
    assert_equal 2, todo_col.jira_board_column_statuses.count
  end

  test "syncs sprints" do
    client = stub_client(
      boards: [{ id: 101, name: "Design", type: "scrum" }],
      board_configs: { 101 => [] },
      sprints: {
        101 => [
          { id: 999, name: "New Sprint", state: "future", start_date: nil, end_date: nil }
        ]
      }
    )

    JiraSyncService.new(@project, client: client).sync

    board = @project.jira_boards.find_by(jira_board_id: 101)
    sprint = board.jira_sprints.find_by(jira_sprint_id: 999)
    assert sprint.present?
    assert_equal "New Sprint", sprint.name
    assert_equal "future", sprint.state
  end

  test "removes stale boards" do
    # design_board (101) and dev_board (102) exist in fixtures
    # Only return board 101 from API — 102 should be removed
    client = stub_client(
      boards: [{ id: 101, name: "Design", type: "scrum" }],
      board_configs: { 101 => [] },
      sprints: {}
    )

    assert @project.jira_boards.find_by(jira_board_id: 102).present?

    JiraSyncService.new(@project, client: client).sync

    assert_nil @project.jira_boards.find_by(jira_board_id: 102)
  end

  test "syncs extended issue fields" do
    client = stub_client(
      boards: [],
      issues: [
        {
          key: "ELV-1",
          summary: "Existing task updated",
          status_category: "indeterminate",
          status_name: "In Progress",
          assignee_email: "one@example.com",
          url: "https://elvium.atlassian.net/browse/ELV-1",
          description: "Updated description",
          priority: "Medium",
          issue_type: "Bug",
          labels: ["backend"],
          reporter_email: "reporter@example.com",
          sprint_id: 569,
          sprint_name: "Design Sprint",
          time_estimate_seconds: 1800
        }
      ]
    )

    JiraSyncService.new(@project, client: client).sync

    task = tasks(:jira_task).reload
    assert_equal "Updated description", task.description
    assert_equal "Medium", task.priority
    assert_equal "Bug", task.issue_type
    assert_equal '["backend"]', task.labels
    assert_equal "reporter@example.com", task.reporter_email
    assert_equal 569, task.sprint_id
    assert_equal "Design Sprint", task.sprint_name
    assert_equal 1800, task.time_estimate_seconds
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bin/rails test test/services/jira_sync_service_boards_test.rb
```

Expected: Failures because sync doesn't handle boards/columns/sprints yet.

- [ ] **Step 3: Implement board/sprint/column sync in JiraSyncService**

Rewrite `app/services/jira_sync_service.rb`:

```ruby
class JiraSyncService
  def initialize(project, client: nil)
    @project = project
    @client = client || JiraClient.new
  end

  def sync
    return unless @project.jira_connected?

    sync_boards
    sync_issues
  end

  private

  def sync_boards
    boards_data = @client.fetch_boards(@project.external_reference)
    return if boards_data.nil?

    synced_board_ids = []

    boards_data.each do |board_data|
      board = @project.jira_boards.find_or_initialize_by(jira_board_id: board_data[:id])
      board.update!(name: board_data[:name], board_type: board_data[:type])
      synced_board_ids << board.id

      sync_board_columns(board, board_data[:id])
      sync_sprints(board, board_data[:id])
    end

    @project.jira_boards.where.not(id: synced_board_ids).destroy_all
  end

  def sync_board_columns(board, jira_board_id)
    columns_data = @client.fetch_board_configuration(jira_board_id)
    return if columns_data.nil?

    synced_column_ids = []

    columns_data.each_with_index do |col_data, position|
      column = board.jira_board_columns.find_or_initialize_by(position: position)
      column.update!(name: col_data[:name])
      synced_column_ids << column.id

      sync_column_statuses(column, col_data[:statuses])
    end

    board.jira_board_columns.where.not(id: synced_column_ids).destroy_all
  end

  def sync_column_statuses(column, statuses_data)
    return if statuses_data.nil?

    synced_status_ids = []

    statuses_data.each do |status_data|
      status = column.jira_board_column_statuses.find_or_initialize_by(jira_status_id: status_data[:id])
      status.update!(jira_status_name: status_data[:name] || "Unknown")
      synced_status_ids << status.id
    end

    column.jira_board_column_statuses.where.not(id: synced_status_ids).destroy_all
  end

  def sync_sprints(board, jira_board_id)
    sprints_data = @client.fetch_sprints(jira_board_id)
    return if sprints_data.nil?

    synced_sprint_ids = []

    sprints_data.each do |sprint_data|
      sprint = board.jira_sprints.find_or_initialize_by(jira_sprint_id: sprint_data[:id])
      sprint.update!(
        name: sprint_data[:name],
        state: sprint_data[:state],
        start_date: sprint_data[:start_date],
        end_date: sprint_data[:end_date]
      )
      synced_sprint_ids << sprint.id
    end

    board.jira_sprints.where.not(id: synced_sprint_ids).destroy_all
  end

  def sync_issues
    issues = @client.fetch_issues(@project.external_reference)
    return if issues.nil?

    issues.each do |issue|
      sync_issue(issue)
    end
  end

  def sync_issue(issue)
    task = @project.tasks.find_or_initialize_by(
      external_reference: issue[:key],
      external_type: "jira"
    )

    name = build_name(issue[:key], issue[:summary])

    task.assign_attributes(
      name: name,
      external_url: issue[:url],
      assignee_email: issue[:assignee_email],
      jira_status_name: issue[:status_name],
      status: map_status(issue[:status_category]),
      description: issue[:description],
      priority: issue[:priority],
      issue_type: issue[:issue_type],
      labels: issue[:labels]&.to_json,
      reporter_email: issue[:reporter_email],
      sprint_id: issue[:sprint_id],
      sprint_name: issue[:sprint_name],
      time_estimate_seconds: issue[:time_estimate_seconds]
    )

    ActiveRecord::Base.transaction(requires_new: true) do
      task.save!
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    task.name = "#{issue[:key]} #{issue[:summary]} [#{issue[:key]}]"
    ActiveRecord::Base.transaction(requires_new: true) { task.save! }
  rescue StandardError => e
    Rails.logger.warn("[JiraSyncService] Failed to sync #{issue[:key]}: #{e.message}")
  end

  def build_name(key, summary)
    "#{key} #{summary}"
  end

  def map_status(status_category)
    case status_category
    when "done" then :done
    else :active
    end
  end
end
```

- [ ] **Step 4: Update existing sync service tests**

The existing tests in `test/services/jira_sync_service_test.rb` use a `stub_client` that only has `fetch_issues`. Since `sync` now calls `fetch_boards` first, update the stub. Replace the `stub_client` method:

```ruby
  def stub_client(issues, project_key = "ELV")
    expected_key = project_key
    expected_issues = issues
    Class.new do
      define_method(:fetch_boards) { |_key| [] }
      define_method(:fetch_issues) do |key|
        raise "Expected #{expected_key}, got #{key}" unless key == expected_key
        expected_issues
      end
    end.new
  end
```

- [ ] **Step 5: Run all sync tests**

```bash
bin/rails test test/services/jira_sync_service_test.rb test/services/jira_sync_service_boards_test.rb
```

Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/services/jira_sync_service.rb test/services/jira_sync_service_test.rb test/services/jira_sync_service_boards_test.rb
git commit -m "feat: extend JiraSyncService to sync boards, sprints, columns, and rich task data"
```

---

## Chunk 4: Controller, Routes, and Navigation

### Task 6: Add routes and controller

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/jira_tasks_controller.rb`
- Create: `test/controllers/jira_tasks_controller_test.rb`

- [ ] **Step 1: Add routes**

In `config/routes.rb`, add after the `get "jira/projects"` line (line 69):

```ruby
  resources :jira_tasks, only: [:index, :show] do
    collection do
      get :board_data
      post :refresh
    end
  end
```

- [ ] **Step 2: Write controller tests**

Create `test/controllers/jira_tasks_controller_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class JiraTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @project = projects(:jira_project)
    @board = jira_boards(:design_board)

    ENV["JIRA_DOMAIN"] = "test.atlassian.net"
    ENV["JIRA_EMAIL"] = "test@example.com"
    ENV["JIRA_API_TOKEN"] = "test-token"
  end

  test "index shows jira tasks page" do
    get jira_tasks_path
    assert_response :success
    assert_select "h1", /Jira Tasks/
  end

  test "index loads project when project_id param given" do
    get jira_tasks_path(project_id: @project.id)
    assert_response :success
  end

  test "index requires employee access" do
    sign_in_as(users(:two))
    get jira_tasks_path
    assert_response :success
  end

  test "board_data returns kanban view" do
    get board_data_jira_tasks_path(project_id: @project.id, board_id: @board.id, view: "kanban")
    assert_response :success
  end

  test "board_data returns list view" do
    get board_data_jira_tasks_path(project_id: @project.id, board_id: @board.id, view: "list")
    assert_response :success
  end

  test "board_data filters by sprint" do
    sprint = jira_sprints(:design_sprint)
    get board_data_jira_tasks_path(project_id: @project.id, board_id: @board.id, sprint_id: sprint.id, view: "kanban")
    assert_response :success
  end

  test "show returns task detail" do
    task = tasks(:jira_task)
    get jira_task_path(task)
    assert_response :success
  end

  test "refresh triggers sync and redirects" do
    # Stub all Jira API calls
    stub_request(:get, /rest\/agile\/1.0\/board\?/)
      .to_return(status: 200, body: { values: [], isLast: true }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, /rest\/api\/3\/search\/jql/)
      .to_return(status: 200, body: { issues: [] }.to_json, headers: { "Content-Type" => "application/json" })

    post refresh_jira_tasks_path(project_id: @project.id)
    assert_response :redirect
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
bin/rails test test/controllers/jira_tasks_controller_test.rb
```

Expected: Routing errors — controller and views don't exist yet.

- [ ] **Step 4: Write the controller**

Create `app/controllers/jira_tasks_controller.rb`:

```ruby
class JiraTasksController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!

  def index
    @jira_projects = current_workspace.projects.active.where(external_type: "jira").order(:name)

    if params[:project_id].present?
      @selected_project = @jira_projects.find_by(id: params[:project_id])
    end
    @selected_project ||= @jira_projects.first

    if @selected_project
      @boards = @selected_project.jira_boards.order(:name)
      @selected_board = if params[:board_id].present?
        @boards.find_by(id: params[:board_id])
      end
      @selected_board ||= @boards.first

      if @selected_board
        @sprints = @selected_board.jira_sprints.active_or_future.order(:name)
        @selected_sprint = @sprints.find_by(id: params[:sprint_id]) if params[:sprint_id].present?
      end
    end

    @view_mode = params[:view].presence || "kanban"
  end

  def board_data
    @selected_project = current_workspace.projects.find(params[:project_id])
    @selected_board = @selected_project.jira_boards.find(params[:board_id])
    @view_mode = params[:view].presence || "kanban"

    @columns = @selected_board.jira_board_columns.includes(:jira_board_column_statuses)

    tasks = @selected_project.tasks.jira_synced
    if params[:sprint_id].present?
      sprint = @selected_board.jira_sprints.find(params[:sprint_id])
      tasks = tasks.where(sprint_id: sprint.jira_sprint_id)
    end

    @tasks_by_column = {}
    @columns.each do |column|
      status_names = column.jira_board_column_statuses.pluck(:jira_status_name)
      @tasks_by_column[column.id] = tasks.where(jira_status_name: status_names).order(:name)
    end

    render partial: @view_mode == "list" ? "list" : "kanban"
  end

  def show
    @task = current_workspace.projects.joins(:tasks).where(tasks: { id: params[:id] }).first&.tasks&.find(params[:id])
    @task ||= Task.joins(:project).where(projects: { workspace_id: current_workspace.id }).find(params[:id])
    render partial: "task_detail"
  end

  def refresh
    project = current_workspace.projects.find(params[:project_id])
    JiraSyncService.new(project).sync
    redirect_to jira_tasks_path(project_id: project.id, board_id: params[:board_id], sprint_id: params[:sprint_id], view: params[:view]),
                notice: "Jira sync complete."
  rescue StandardError => e
    Rails.logger.error("[JiraTasksController] Refresh failed: #{e.message}")
    redirect_to jira_tasks_path(project_id: params[:project_id]), alert: "Could not sync with Jira. Please try again."
  end
end
```

- [ ] **Step 5: Run tests (will fail — views not yet created)**

```bash
bin/rails test test/controllers/jira_tasks_controller_test.rb
```

Expected: Tests fail with missing template errors. That's fine — we'll create views in the next task.

- [ ] **Step 6: Commit controller and routes**

```bash
git add config/routes.rb app/controllers/jira_tasks_controller.rb test/controllers/jira_tasks_controller_test.rb
git commit -m "feat: add JiraTasksController with routes and tests"
```

### Task 7: Add navigation link

**Files:**
- Modify: `app/views/layouts/application.html.erb:60-61`

- [ ] **Step 1: Add Jira Tasks nav item**

In `app/views/layouts/application.html.erb`, after the Timesheet link block (after line 60, which is `<% end %>` closing the Timesheet link), add:

```erb
              <% if current_workspace.projects.active.where(external_type: "jira").exists? %>
                <%= link_to jira_tasks_path, class: "m3-nav-item #{request.path.start_with?('/jira_tasks') ? 'active' : ''}" do %>
                  <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M9 4.5v15m6-15v15m-10.875 0h15.75c.621 0 1.125-.504 1.125-1.125V5.625c0-.621-.504-1.125-1.125-1.125H4.125C3.504 4.5 3 5.004 3 5.625v12.75c0 .621.504 1.125 1.125 1.125z" /></svg>
                  <span>Jira Tasks</span>
                <% end %>
              <% end %>
```

- [ ] **Step 2: Commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "feat: add Jira Tasks link to sidebar navigation"
```

---

## Chunk 5: Views

### Task 8: Create the index view and partials

**Files:**
- Create: `app/views/jira_tasks/index.html.erb`
- Create: `app/views/jira_tasks/_kanban.html.erb`
- Create: `app/views/jira_tasks/_list.html.erb`
- Create: `app/views/jira_tasks/_task_detail.html.erb`
- Create: `app/views/jira_tasks/_empty_state.html.erb`

- [ ] **Step 1: Create index.html.erb**

```erb
<% content_for(:title, "Jira Tasks") %>

<div class="space-y-5" data-controller="jira-tasks" data-jira-tasks-current-view-value="<%= @view_mode %>">
  <%# Header %>
  <div class="flex justify-between items-center">
    <h1 class="text-2xl font-bold tracking-tight" style="color: var(--color-on-surface)">Jira Tasks</h1>
    <% if @selected_project %>
      <button type="button"
              class="m3-btn m3-btn-outlined m3-btn-sm flex items-center gap-1.5"
              data-jira-tasks-target="refreshButton"
              data-action="click->jira-tasks#refresh">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182M2.985 19.644l3.181-3.182" />
        </svg>
        Refresh
      </button>
    <% end %>
  </div>

  <%# Filter bar %>
  <div class="flex flex-wrap items-center gap-3 p-3 rounded-xl" style="background: var(--color-surface-container)">
    <%# Project selector %>
    <div class="flex-shrink-0">
      <select class="m3-text-field text-sm min-w-[180px]"
              data-jira-tasks-target="projectSelect"
              data-action="change->jira-tasks#projectChanged">
        <% @jira_projects.each do |project| %>
          <option value="<%= project.id %>" <%= "selected" if @selected_project == project %>>
            <%= project.name %>
          </option>
        <% end %>
      </select>
    </div>

    <% if @boards&.any? %>
      <%# Board selector %>
      <div class="flex-shrink-0">
        <select class="m3-text-field text-sm min-w-[150px]"
                data-jira-tasks-target="boardSelect"
                data-action="change->jira-tasks#boardChanged">
          <% @boards.each do |board| %>
            <option value="<%= board.id %>" <%= "selected" if @selected_board == board %>>
              <%= board.name %>
            </option>
          <% end %>
        </select>
      </div>

      <% if @sprints&.any? %>
        <%# Sprint selector %>
        <div class="flex-shrink-0">
          <select class="m3-text-field text-sm min-w-[150px]"
                  data-jira-tasks-target="sprintSelect"
                  data-action="change->jira-tasks#sprintChanged">
            <option value="">All sprints</option>
            <% @sprints.each do |sprint| %>
              <option value="<%= sprint.id %>" <%= "selected" if @selected_sprint == sprint %>>
                <%= sprint.name %> (<%= sprint.state %>)
              </option>
            <% end %>
          </select>
        </div>
      <% end %>
    <% end %>

    <%# View toggle %>
    <div class="ml-auto flex rounded-lg overflow-hidden border" style="border-color: var(--color-outline-variant)">
      <button type="button"
              class="px-3 py-1.5 text-sm font-medium transition-colors <%= @view_mode == 'kanban' ? '' : '' %>"
              style="<%= @view_mode == 'kanban' ? 'background: var(--color-primary); color: var(--color-on-primary)' : 'background: var(--color-surface); color: var(--color-on-surface-variant)' %>"
              data-action="click->jira-tasks#toggleView"
              data-jira-tasks-target="viewToggle"
              data-view="kanban">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 inline" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M9 4.5v15m6-15v15m-10.875 0h15.75c.621 0 1.125-.504 1.125-1.125V5.625c0-.621-.504-1.125-1.125-1.125H4.125C3.504 4.5 3 5.004 3 5.625v12.75c0 .621.504 1.125 1.125 1.125z" />
        </svg>
        Board
      </button>
      <button type="button"
              class="px-3 py-1.5 text-sm font-medium transition-colors"
              style="<%= @view_mode == 'list' ? 'background: var(--color-primary); color: var(--color-on-primary)' : 'background: var(--color-surface); color: var(--color-on-surface-variant)' %>"
              data-action="click->jira-tasks#toggleView"
              data-jira-tasks-target="viewToggle"
              data-view="list">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 inline" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 6.75h12M8.25 12h12m-12 5.25h12M3.75 6.75h.007v.008H3.75V6.75zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zM3.75 12h.007v.008H3.75V12zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm-.375 5.25h.007v.008H3.75v-.008zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0z" />
        </svg>
        List
      </button>
    </div>
  </div>

  <%# Board content %>
  <turbo-frame id="jira-board-content"
               data-jira-tasks-target="boardContent"
               <% if @selected_project && @selected_board %>
                 src="<%= board_data_jira_tasks_path(project_id: @selected_project.id, board_id: @selected_board.id, sprint_id: @selected_sprint&.id, view: @view_mode) %>"
               <% end %>
               >
    <% if @jira_projects.empty? %>
      <%= render "empty_state", message: "No projects with Jira integration found." %>
    <% elsif @selected_project && @boards&.empty? %>
      <%= render "empty_state", message: "No boards found for #{@selected_project.name}. Try refreshing." %>
    <% else %>
      <div class="flex items-center justify-center py-12">
        <div class="animate-spin h-6 w-6 border-2 rounded-full" style="border-color: var(--color-outline-variant); border-top-color: var(--color-primary)"></div>
      </div>
    <% end %>
  </turbo-frame>

  <%# Task detail modal %>
  <div data-controller="jira-task-modal" data-jira-task-modal-target="modal" class="hidden fixed inset-0 z-50 flex items-center justify-center">
    <div class="absolute inset-0" style="background: rgba(0,0,0,0.5)" data-action="click->jira-task-modal#close"></div>
    <div class="relative m3-card-elevated max-w-2xl w-full mx-4 max-h-[85vh] overflow-y-auto" style="z-index: 1">
      <turbo-frame id="jira-task-detail" data-jira-task-modal-target="content">
      </turbo-frame>
    </div>
  </div>
</div>
```

- [ ] **Step 2: Create _kanban.html.erb**

```erb
<turbo-frame id="jira-board-content">
  <% if @columns.empty? %>
    <%= render "empty_state", message: "No columns configured for this board." %>
  <% else %>
    <div class="flex gap-4 overflow-x-auto pb-4" style="min-height: 400px">
      <% @columns.each do |column| %>
        <% tasks = @tasks_by_column[column.id] || [] %>
        <div class="flex-shrink-0 w-64 flex flex-col">
          <%# Column header %>
          <div class="flex items-center justify-between px-3 py-2 rounded-t-lg" style="background: var(--color-surface-container-high)">
            <span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">
              <%= column.name %>
            </span>
            <span class="text-xs font-medium px-1.5 py-0.5 rounded-full" style="background: var(--color-surface-container-highest); color: var(--color-on-surface-variant)">
              <%= tasks.size %>
            </span>
          </div>

          <%# Cards %>
          <div class="flex-1 space-y-2 p-2 rounded-b-lg" style="background: var(--color-surface-container-low)">
            <% if tasks.empty? %>
              <div class="py-6 text-center text-xs" style="color: var(--color-outline)">No tasks</div>
            <% end %>
            <% tasks.each do |task| %>
              <div class="p-3 rounded-lg cursor-pointer transition-shadow hover:shadow-md"
                   style="background: var(--color-surface); border: 1px solid var(--color-outline-variant)"
                   data-action="click->jira-task-modal#open"
                   data-task-id="<%= task.id %>"
                   data-task-url="<%= jira_task_path(task) %>">
                <%# Issue key %>
                <div class="flex items-center justify-between mb-1.5">
                  <a href="<%= task.external_url %>" target="_blank" rel="noopener"
                     class="text-xs font-semibold hover:underline"
                     style="color: var(--color-primary)"
                     onclick="event.stopPropagation()">
                    <%= task.external_reference %>
                  </a>
                  <% if task.issue_type.present? %>
                    <span class="text-[0.6rem] px-1.5 py-0.5 rounded" style="background: var(--color-tertiary-container); color: var(--color-on-tertiary-container)">
                      <%= task.issue_type %>
                    </span>
                  <% end %>
                </div>

                <%# Summary %>
                <p class="text-sm leading-snug mb-2 line-clamp-2" style="color: var(--color-on-surface)">
                  <%= task.name.sub(/\A#{Regexp.escape(task.external_reference.to_s)}\s*/, '') %>
                </p>

                <%# Footer: priority + assignee %>
                <div class="flex items-center justify-between">
                  <% if task.priority.present? %>
                    <span class="text-xs flex items-center gap-1" style="color: var(--color-on-surface-variant)">
                      <% case task.priority.downcase %>
                      <% when "highest", "high" %>
                        <svg class="h-3.5 w-3.5" style="color: var(--color-error)" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M14.77 12.79a.75.75 0 01-1.06-.02L10 8.832 6.29 12.77a.75.75 0 11-1.08-1.04l4.25-4.5a.75.75 0 011.08 0l4.25 4.5a.75.75 0 01-.02 1.06z" clip-rule="evenodd" /></svg>
                      <% when "medium" %>
                        <svg class="h-3.5 w-3.5" style="color: var(--color-tertiary)" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M3 10a.75.75 0 01.75-.75h12.5a.75.75 0 010 1.5H3.75A.75.75 0 013 10z" clip-rule="evenodd" /></svg>
                      <% when "low", "lowest" %>
                        <svg class="h-3.5 w-3.5" style="color: var(--color-primary)" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M5.23 7.21a.75.75 0 011.06.02L10 11.168l3.71-3.938a.75.75 0 111.08 1.04l-4.25 4.5a.75.75 0 01-1.08 0l-4.25-4.5a.75.75 0 01.02-1.06z" clip-rule="evenodd" /></svg>
                      <% end %>
                      <%= task.priority %>
                    </span>
                  <% else %>
                    <span></span>
                  <% end %>

                  <% if task.assignee_email.present? %>
                    <div class="m3-avatar" style="width: 24px; height: 24px; font-size: 0.6rem">
                      <%= task.assignee_email.first(2).upcase %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
  <% end %>
</turbo-frame>
```

- [ ] **Step 3: Create _list.html.erb**

```erb
<turbo-frame id="jira-board-content">
  <% all_tasks = @tasks_by_column.values.flatten %>
  <% if all_tasks.empty? %>
    <%= render "empty_state", message: "No tasks found." %>
  <% else %>
    <div class="m3-card-outlined overflow-hidden">
      <table class="m3-table w-full">
        <thead>
          <tr>
            <th class="text-left text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">Key</th>
            <th class="text-left text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">Summary</th>
            <th class="text-left text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">Status</th>
            <th class="text-left text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">Assignee</th>
            <th class="text-left text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">Priority</th>
            <th class="text-left text-xs font-semibold uppercase tracking-wider" style="color: var(--color-on-surface-variant)">Type</th>
          </tr>
        </thead>
        <tbody>
          <% all_tasks.each do |task| %>
            <tr class="cursor-pointer transition-colors"
                style="border-bottom: 1px solid var(--color-outline-variant)"
                onmouseover="this.style.background='var(--color-surface-container)'"
                onmouseout="this.style.background='transparent'"
                data-action="click->jira-task-modal#open"
                data-task-id="<%= task.id %>"
                data-task-url="<%= jira_task_path(task) %>">
              <td class="py-3 px-4">
                <a href="<%= task.external_url %>" target="_blank" rel="noopener"
                   class="text-sm font-semibold hover:underline"
                   style="color: var(--color-primary)"
                   onclick="event.stopPropagation()">
                  <%= task.external_reference %>
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3 inline ml-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
                  </svg>
                </a>
              </td>
              <td class="py-3 px-4 text-sm max-w-xs truncate" style="color: var(--color-on-surface)">
                <%= task.name.sub(/\A#{Regexp.escape(task.external_reference.to_s)}\s*/, '') %>
              </td>
              <td class="py-3 px-4">
                <span class="text-xs px-2 py-0.5 rounded-full" style="background: var(--color-secondary-container); color: var(--color-on-secondary-container)">
                  <%= task.jira_status_name %>
                </span>
              </td>
              <td class="py-3 px-4 text-sm" style="color: var(--color-on-surface-variant)">
                <%= task.assignee_email&.split("@")&.first || "—" %>
              </td>
              <td class="py-3 px-4 text-sm" style="color: var(--color-on-surface-variant)">
                <%= task.priority || "—" %>
              </td>
              <td class="py-3 px-4 text-sm" style="color: var(--color-on-surface-variant)">
                <%= task.issue_type || "—" %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% end %>
</turbo-frame>
```

- [ ] **Step 4: Create _task_detail.html.erb**

```erb
<turbo-frame id="jira-task-detail">
  <div class="p-6 space-y-5">
    <%# Header %>
    <div class="flex items-start justify-between">
      <div>
        <div class="flex items-center gap-2 mb-1">
          <a href="<%= @task.external_url %>" target="_blank" rel="noopener"
             class="text-sm font-semibold hover:underline"
             style="color: var(--color-primary)">
            <%= @task.external_reference %>
            <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3 inline" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
            </svg>
          </a>
        </div>
        <h2 class="text-xl font-bold" style="color: var(--color-on-surface)">
          <%= @task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, '') %>
        </h2>
      </div>
      <button type="button" class="p-1 rounded-lg transition-colors" style="color: var(--color-on-surface-variant)"
              data-action="click->jira-task-modal#close"
              onmouseover="this.style.background='var(--color-surface-container-high)'"
              onmouseout="this.style.background='transparent'">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <%# Status + Type badges %>
    <div class="flex items-center gap-2">
      <span class="text-xs px-2 py-1 rounded-full font-medium" style="background: var(--color-secondary-container); color: var(--color-on-secondary-container)">
        <%= @task.jira_status_name %>
      </span>
      <% if @task.issue_type.present? %>
        <span class="text-xs px-2 py-1 rounded-full font-medium" style="background: var(--color-tertiary-container); color: var(--color-on-tertiary-container)">
          <%= @task.issue_type %>
        </span>
      <% end %>
    </div>

    <% if @task.description.present? %>
      <div>
        <h3 class="text-sm font-semibold mb-2" style="color: var(--color-on-surface-variant)">Description</h3>
        <div class="text-sm leading-relaxed whitespace-pre-wrap p-3 rounded-lg" style="color: var(--color-on-surface); background: var(--color-surface-container-low)">
          <%= @task.description %>
        </div>
      </div>
    <% end %>

    <%# Details grid %>
    <div>
      <h3 class="text-sm font-semibold mb-2" style="color: var(--color-on-surface-variant)">Details</h3>
      <div class="grid grid-cols-2 gap-y-3 gap-x-6 text-sm">
        <div>
          <dt style="color: var(--color-outline)">Assignee</dt>
          <dd class="font-medium" style="color: var(--color-on-surface)"><%= @task.assignee_email || "Unassigned" %></dd>
        </div>
        <div>
          <dt style="color: var(--color-outline)">Reporter</dt>
          <dd class="font-medium" style="color: var(--color-on-surface)"><%= @task.reporter_email || "—" %></dd>
        </div>
        <div>
          <dt style="color: var(--color-outline)">Priority</dt>
          <dd class="font-medium" style="color: var(--color-on-surface)"><%= @task.priority || "—" %></dd>
        </div>
        <div>
          <dt style="color: var(--color-outline)">Sprint</dt>
          <dd class="font-medium" style="color: var(--color-on-surface)"><%= @task.sprint_name || "—" %></dd>
        </div>

        <% if @task.labels.present? %>
          <% labels = begin; JSON.parse(@task.labels); rescue; []; end %>
          <% if labels.any? %>
            <div class="col-span-2">
              <dt style="color: var(--color-outline)">Labels</dt>
              <dd class="flex flex-wrap gap-1 mt-0.5">
                <% labels.each do |label| %>
                  <span class="text-xs px-2 py-0.5 rounded-full" style="background: var(--color-surface-container-highest); color: var(--color-on-surface-variant)">
                    <%= label %>
                  </span>
                <% end %>
              </dd>
            </div>
          <% end %>
        <% end %>

        <% if @task.time_estimate_seconds.present? && @task.time_estimate_seconds > 0 %>
          <div>
            <dt style="color: var(--color-outline)">Estimate</dt>
            <dd class="font-medium" style="color: var(--color-on-surface)">
              <%= @task.time_estimate_seconds / 3600 %>h <%= (@task.time_estimate_seconds % 3600) / 60 %>m
            </dd>
          </div>
        <% end %>
      </div>
    </div>

    <%# View in Jira button %>
    <div class="pt-2">
      <a href="<%= @task.external_url %>" target="_blank" rel="noopener"
         class="m3-btn m3-btn-filled inline-flex items-center gap-2">
        View in Jira
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
        </svg>
      </a>
    </div>
  </div>
</turbo-frame>
```

- [ ] **Step 5: Create _empty_state.html.erb**

```erb
<div class="flex flex-col items-center justify-center py-16">
  <svg xmlns="http://www.w3.org/2000/svg" class="h-12 w-12 mb-3" style="color: var(--color-outline)" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
    <path stroke-linecap="round" stroke-linejoin="round" d="M20.25 7.5l-.625 10.632a2.25 2.25 0 01-2.247 2.118H6.622a2.25 2.25 0 01-2.247-2.118L3.75 7.5m6 4.125l2.25 2.25m0 0l2.25 2.25M12 13.875l2.25-2.25M12 13.875l-2.25 2.25M3.375 7.5h17.25c.621 0 1.125-.504 1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125z" />
  </svg>
  <p class="text-sm" style="color: var(--color-outline)"><%= message %></p>
</div>
```

- [ ] **Step 6: Run controller tests**

```bash
bin/rails test test/controllers/jira_tasks_controller_test.rb
```

Expected: All tests pass now that views exist.

- [ ] **Step 7: Commit**

```bash
git add app/views/jira_tasks/
git commit -m "feat: add Jira Tasks views — index, kanban, list, task detail modal, empty state"
```

---

## Chunk 6: Stimulus Controllers

### Task 9: Create Stimulus controllers

**Files:**
- Create: `app/javascript/controllers/jira_tasks_controller.js`
- Create: `app/javascript/controllers/jira_task_modal_controller.js`

- [ ] **Step 1: Create jira_tasks_controller.js**

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["projectSelect", "boardSelect", "sprintSelect", "boardContent", "viewToggle", "refreshButton"]
  static values = { currentView: { type: String, default: "kanban" } }

  projectChanged() {
    const projectId = this.projectSelectTarget.value
    if (!projectId) return

    // Reload page with new project
    window.location.href = `/jira_tasks?project_id=${projectId}&view=${this.currentViewValue}`
  }

  boardChanged() {
    this.reloadBoardContent()
  }

  sprintChanged() {
    this.reloadBoardContent()
  }

  toggleView(event) {
    const view = event.currentTarget.dataset.view
    if (view === this.currentViewValue) return

    this.currentViewValue = view

    // Update toggle button styles
    this.viewToggleTargets.forEach(btn => {
      const isActive = btn.dataset.view === view
      btn.style.background = isActive ? "var(--color-primary)" : "var(--color-surface)"
      btn.style.color = isActive ? "var(--color-on-primary)" : "var(--color-on-surface-variant)"
    })

    this.reloadBoardContent()
  }

  refresh() {
    const projectId = this.hasProjectSelectTarget ? this.projectSelectTarget.value : null
    if (!projectId) return

    const btn = this.refreshButtonTarget
    btn.disabled = true
    btn.innerHTML = `<svg class="animate-spin h-4 w-4" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg> Syncing...`

    const params = new URLSearchParams({ project_id: projectId })
    if (this.hasBoardSelectTarget) params.set("board_id", this.boardSelectTarget.value)
    if (this.hasSprintSelectTarget && this.sprintSelectTarget.value) params.set("sprint_id", this.sprintSelectTarget.value)
    params.set("view", this.currentViewValue)

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(`/jira_tasks/refresh?${params}`, {
      method: "POST",
      headers: {
        "X-CSRF-Token": csrfToken,
        "Accept": "text/html"
      }
    }).then(response => {
      if (response.redirected) {
        window.location.href = response.url
      } else {
        window.location.reload()
      }
    }).catch(() => {
      window.location.reload()
    })
  }

  reloadBoardContent() {
    if (!this.hasBoardContentTarget) return

    const projectId = this.hasProjectSelectTarget ? this.projectSelectTarget.value : null
    const boardId = this.hasBoardSelectTarget ? this.boardSelectTarget.value : null
    if (!projectId || !boardId) return

    const params = new URLSearchParams({
      project_id: projectId,
      board_id: boardId,
      view: this.currentViewValue
    })

    if (this.hasSprintSelectTarget && this.sprintSelectTarget.value) {
      params.set("sprint_id", this.sprintSelectTarget.value)
    }

    this.boardContentTarget.src = `/jira_tasks/board_data?${params}`
  }
}
```

- [ ] **Step 2: Create jira_task_modal_controller.js**

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "content"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
  }

  open(event) {
    // Don't open modal if clicking a link
    if (event.target.closest("a")) return

    const taskUrl = event.currentTarget.dataset.taskUrl
    if (!taskUrl) return

    this.contentTarget.src = taskUrl
    this.modalTarget.classList.remove("hidden")
    document.addEventListener("keydown", this.handleKeydown)
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    this.contentTarget.innerHTML = ""
    this.contentTarget.removeAttribute("src")
    document.removeEventListener("keydown", this.handleKeydown)
    document.body.style.overflow = ""
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }
}
```

- [ ] **Step 3: Register controllers in the import map**

Check if Stimulus controllers auto-register (they do in Rails 8.1 with importmap + stimulus-loading). The files just need to be in `app/javascript/controllers/` with the right naming convention. No manual registration needed.

- [ ] **Step 4: Commit**

```bash
git add app/javascript/controllers/jira_tasks_controller.js app/javascript/controllers/jira_task_modal_controller.js
git commit -m "feat: add Stimulus controllers for Jira Tasks page (filters, view toggle, modal)"
```

---

## Chunk 7: Final Integration and Full Test Run

### Task 10: Run full test suite and fix any issues

- [ ] **Step 1: Run the full test suite**

```bash
bin/rails test
```

Expected: All tests pass.

- [ ] **Step 2: Fix any failing tests**

Address any failures. Common issues:
- Existing tests may need fixture updates due to new required fields
- The `jira_sync_service_test.rb` stub_client may need `fetch_boards` method

- [ ] **Step 3: Manually verify in browser**

```bash
bin/rails server
```

Visit `/jira_tasks` and verify:
- Project selector shows only Jira-connected projects
- Board selector populates when project selected
- Sprint filter works
- Kanban view shows columns with cards
- List view shows table
- View toggle works
- Clicking a task opens the detail modal
- Refresh button triggers sync
- Navigation link appears in sidebar

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve integration issues from full test run"
```
