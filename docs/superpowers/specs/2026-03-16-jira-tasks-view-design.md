# Jira Tasks View — Design Spec

## Overview

Add a new top-level "Jira Tasks" page that displays Jira issues in both Kanban board and list views. The view includes a project selector (only Jira-connected projects), board selector, sprint filter, a manual refresh button, and a centered modal for viewing task details.

## Data Model

### New Tables

**jira_boards**
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| project_id | bigint FK | references projects |
| jira_board_id | integer | Jira's board ID |
| name | string | e.g. "Design", "DEV board" |
| board_type | string | "scrum" or "kanban" |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `[project_id, jira_board_id]` unique

**jira_sprints**
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| jira_board_id | bigint FK | references jira_boards |
| jira_sprint_id | integer | Jira's sprint ID |
| name | string | e.g. "Design Sprint" |
| state | string | "active", "closed", "future" |
| start_date | datetime | nullable |
| end_date | datetime | nullable |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `[jira_board_id, jira_sprint_id]` unique

**jira_board_columns**
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| jira_board_id | bigint FK | references jira_boards |
| name | string | e.g. "TO DO (DESIGN)" |
| position | integer | column ordering |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `[jira_board_id, position]` unique

**jira_board_column_statuses**
| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| jira_board_column_id | bigint FK | references jira_board_columns |
| jira_status_name | string | status name mapped to this column |
| jira_status_id | string | Jira's status ID |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `[jira_board_column_id, jira_status_id]` unique

### Extended Task Fields

Add to existing `tasks` table:
- `description` (text) — Jira issue description (plain text, extracted from ADF)
- `priority` (string) — e.g. "High", "Medium", "Low"
- `issue_type` (string) — e.g. "Story", "Bug", "Task"
- `labels` (text) — JSON array of label strings
- `reporter_email` (string)
- `sprint_name` (string) — name of the current sprint
- `sprint_id` (integer) — Jira's sprint ID for filtering
- `time_estimate_seconds` (integer) — original estimate

### Model Associations

```ruby
# Project
has_many :jira_boards, dependent: :destroy

# JiraBoard
belongs_to :project
has_many :jira_sprints, dependent: :destroy
has_many :jira_board_columns, -> { order(:position) }, dependent: :destroy

# JiraSprint
belongs_to :jira_board

# JiraBoardColumn
belongs_to :jira_board
has_many :jira_board_column_statuses, dependent: :destroy

# JiraBoardColumnStatus
belongs_to :jira_board_column
```

## Jira API Client Extensions

Extend `JiraClient` with new methods using the Jira Agile REST API:

### `fetch_boards(project_key)`
- Endpoint: `GET /rest/agile/1.0/board?projectKeyOrId=KEY`
- Returns: `[{ id:, name:, type: }]`

### `fetch_board_configuration(board_id)`
- Endpoint: `GET /rest/agile/1.0/board/{id}/configuration`
- Returns column names with their mapped status IDs and names
- Response structure: `{ columnConfig: { columns: [{ name:, statuses: [{ id:, self: }] }] } }`

### `fetch_sprints(board_id)`
- Endpoint: `GET /rest/agile/1.0/board/{id}/sprint`
- Returns: `[{ id:, name:, state:, startDate:, endDate: }]`
- Paginated — handle `isLast` flag

### Extended `fetch_issues`
Add these fields to the JQL `fields` parameter:
- `description` — ADF format, convert to plain text
- `priority` — `{ name: "High" }`
- `issuetype` — `{ name: "Story" }`
- `labels` — `["Feature", "HR"]`
- `reporter` — `{ emailAddress: "..." }`
- `sprint` — `{ id:, name: }` (from agile fields)
- `timeoriginalestimate` — seconds

### ADF to Plain Text
Add a private helper `adf_to_text(adf_node)` that recursively extracts text content from Atlassian Document Format JSON. Handles: `paragraph`, `heading`, `text`, `bulletList`, `orderedList`, `listItem`, `codeBlock`, `blockquote`. Returns plain text with newlines for block elements.

## Sync Service Extensions

Extend `JiraSyncService` to:

1. **Sync boards** — Fetch all boards for the project, create/update `JiraBoard` records
2. **Sync board configurations** — For each board, fetch column config, create/update `JiraBoardColumn` and `JiraBoardColumnStatus` records. Remove stale columns/statuses.
3. **Sync sprints** — For each board, fetch sprints, create/update `JiraSprint` records
4. **Sync richer task data** — Extend existing issue sync to populate the new fields (description, priority, issue_type, labels, reporter_email, sprint_name, sprint_id, time_estimate_seconds)

The sync order: boards → board configurations → sprints → issues (existing + extended).

Stale data cleanup: Remove boards/columns/sprints that no longer exist in Jira.

## Routes

```ruby
resources :jira_tasks, only: [:index] do
  collection do
    get :board_data    # Returns board columns + tasks for Turbo Frame
    post :refresh      # Triggers manual sync, returns Turbo Stream
  end
  member do
    get :show          # Returns task detail HTML for modal (Turbo Frame)
  end
end
```

## Controller

`JiraTasksController` — new controller.

### `#index`
- Auth: `require_employee!`
- Loads Jira-connected projects: `current_workspace.projects.active.where(external_type: "jira")`
- If a `project_id` param is present, loads boards and sprints for that project
- Sets `@selected_project`, `@selected_board`, `@selected_sprint`
- Default board: first board alphabetically (or user's last selection via cookie/param)
- Renders the full page with Turbo Frames for the board content area

### `#board_data`
- Auth: `require_employee!`
- Params: `project_id`, `board_id`, `sprint_id` (optional), `view` ("kanban" or "list")
- Loads board columns with statuses
- Loads tasks filtered by sprint (if selected) and grouped by column
- Responds with a Turbo Frame containing either the Kanban or list view partial

### `#show`
- Auth: `require_employee!`
- Loads a single task with all Jira fields
- Renders a Turbo Frame for the modal content

### `#refresh`
- Auth: `require_employee!`
- Triggers `JiraSyncService.new(project).sync` (which now includes boards/sprints/columns)
- Responds with Turbo Stream that replaces the board data frame and shows a flash

## Views

### `app/views/jira_tasks/index.html.erb`

Page structure:
```
┌─────────────────────────────────────────────────────┐
│ Jira Tasks                          [Refresh ↻]     │
├─────────────────────────────────────────────────────┤
│ [Project ▼]  [Board ▼]  [Sprint ▼]  [List|Kanban]  │
├─────────────────────────────────────────────────────┤
│                                                     │
│  <turbo-frame id="jira-board-content">              │
│    (Kanban or List view loaded here)                │
│  </turbo-frame>                                     │
│                                                     │
└─────────────────────────────────────────────────────┘
```

- Project selector: `<select>` with only Jira-connected projects
- Board selector: `<select>` populated when project selected
- Sprint selector: `<select>` with "All sprints" default + active/future sprints
- View toggle: two buttons (list icon / kanban icon) that toggle between views
- Refresh button: triggers manual sync with loading spinner

### Kanban View (`_kanban.html.erb`)

```
┌──────────┬──────────┬──────────┬──────────┐
│ TO DO(3) │ IN PR(2) │ REVIEW(1)│ DONE(5)  │
├──────────┼──────────┼──────────┼──────────┤
│ ┌──────┐ │ ┌──────┐ │ ┌──────┐ │ ┌──────┐ │
│ │DEV-99│ │ │DEV-42│ │ │DEV-11│ │ │DEV-05│ │
│ │Title │ │ │Title │ │ │Title │ │ │Title │ │
│ │▲ High│ │ │= Med │ │ │▼ Low │ │ │= Med │ │
│ │  @MM │ │ │  @KT │ │ │  @JA │ │ │  @KN │ │
│ └──────┘ │ └──────┘ │ └──────┘ │ └──────┘ │
│ ┌──────┐ │          │          │ ┌──────┐ │
│ │DEV-88│ │          │          │ │DEV-03│ │
│ │Title │ │          │          │ │Title │ │
│ └──────┘ │          │          │ └──────┘ │
└──────────┴──────────┴──────────┴──────────┘
```

- Horizontal scroll for many columns
- Each column header shows column name + task count
- Cards show: issue key (as link), summary (truncated), priority icon, assignee initials avatar
- Cards are clickable to open the detail modal
- Columns are ordered by `jira_board_columns.position`

### List View (`_list.html.erb`)

Table with columns:
| Key | Summary | Status | Assignee | Priority | Type |
- Sortable by clicking column headers (client-side with Stimulus)
- Rows are clickable to open the detail modal
- Issue key links to Jira (external_url) with a small external link icon

### Task Detail Modal (`_task_detail.html.erb`)

Centered modal (using existing m3 styling patterns). Layout:

```
┌─────────────────────────────────────────────┐
│ DEV-799                              [✕]    │
│─────────────────────────────────────────────│
│                                             │
│ Elvium Talent                               │
│ Status: To Do    Type: Story                │
│                                             │
│ ── Description ──────────────────────────── │
│ Elvium Talent – MVP Product Description     │
│ Background: Elvium currently covers two...  │
│                                             │
│ ── Details ──────────────────────────────── │
│ Assignee:    Mark Marczak                   │
│ Reporter:    Jesper Andersen                │
│ Priority:    ▲ High                         │
│ Labels:      Feature, HR                    │
│ Sprint:      Design Sprint                  │
│ Estimate:    0m                             │
│                                             │
│        [View in Jira ↗]                     │
└─────────────────────────────────────────────┘
```

- Opens as a Turbo Frame loaded via `jira_tasks/:id` into a modal container
- "View in Jira" button links to `task.external_url`
- Close button and click-outside-to-close behavior

## Stimulus Controllers

### `jira-tasks-controller`

Manages the filter bar interactions:

- **Targets**: `projectSelect`, `boardSelect`, `sprintSelect`, `boardContent`, `viewToggle`, `refreshButton`
- **Values**: `currentView` (string, default "kanban")
- **Actions**:
  - `projectChanged` — When project selector changes, fetch boards/sprints via Turbo Frame src update
  - `boardChanged` — When board selector changes, reload board content
  - `sprintChanged` — When sprint selector changes, reload board content
  - `toggleView` — Switch between kanban/list, reload board content with new view param
  - `refresh` — POST to refresh endpoint, show loading state on button, reload on completion

### `jira-task-modal-controller`

Manages the detail modal:

- **Targets**: `modal`, `content`
- **Actions**:
  - `open` — Load task detail via Turbo Frame, show modal with backdrop
  - `close` — Hide modal, clear content
  - `backdropClick` — Close if clicked outside modal content

## Navigation

Add "Jira Tasks" to the sidebar navigation, visible to employees (same visibility as Time Entries). Place it after "Timesheet" and before the "Manage" section. Only show if the workspace has at least one Jira-connected project.

Icon: Jira-style board icon (use Heroicons `view-columns` or similar).

## Error Handling

- If Jira API is unreachable during refresh, show a flash error: "Could not sync with Jira. Please try again."
- If no boards exist for a project, show an empty state: "No boards found for this project."
- If no tasks match the current filters, show: "No tasks found."
- Loading states: skeleton placeholders while Turbo Frames load

## Testing

### Model Tests
- JiraBoard, JiraSprint, JiraBoardColumn, JiraBoardColumnStatus — validations and associations

### Service Tests
- Extended JiraSyncService — boards, sprints, columns sync
- JiraClient — new API methods with webmock stubs

### Controller Tests
- JiraTasksController#index — auth, project filtering, board/sprint loading
- JiraTasksController#board_data — kanban/list rendering, sprint filtering
- JiraTasksController#show — task detail loading
- JiraTasksController#refresh — sync trigger

### Fixtures
- Add jira_board, jira_sprint, jira_board_column, jira_board_column_status fixtures
- Extend jira_task fixture with new fields

## Migration Plan

1. Create `jira_boards` table
2. Create `jira_sprints` table
3. Create `jira_board_columns` table
4. Create `jira_board_column_statuses` table
5. Add new columns to `tasks` table

All in a single migration file since they're part of one feature.
