# Feedback Meetings Design Spec

## Overview

Feedback meetings allow admins to schedule one-on-one meetings with employees and track notes. Employees see their own meetings but cannot modify them. Admins control note visibility per meeting.

## Data Model

Single `FeedbackMeeting` model, workspace-scoped.

### Schema

```sql
create_table :feedback_meetings do |t|
  t.references :workspace, null: false, foreign_key: true
  t.references :creator, null: false, foreign_key: { to_table: :users }
  t.references :employee, null: false, foreign_key: { to_table: :users }
  t.string :title, null: false
  t.datetime :scheduled_at, null: false
  t.text :notes
  t.boolean :notes_visible, default: false, null: false
  t.timestamps
end

add_index :feedback_meetings, [:workspace_id, :employee_id]
add_index :feedback_meetings, [:workspace_id, :scheduled_at]
```

### Fields

- `workspace_id` — scoping to current workspace
- `creator_id` — the admin who created the meeting
- `employee_id` — the invited employee
- `title` — meeting title (required)
- `scheduled_at` — date and time of the meeting (required)
- `notes` — plain text notes field, written by admin only
- `notes_visible` — boolean toggle; when false, employee cannot see notes

## Authorization

### Roles

| Action              | Admin/Owner | Employee                         |
|---------------------|-------------|----------------------------------|
| List all meetings   | Yes         | Only their own                   |
| View meeting        | Yes         | Only their own                   |
| View notes          | Yes         | Only when `notes_visible` is true|
| Create meeting      | Yes         | No                               |
| Edit meeting        | Yes         | No                               |
| Delete meeting      | Yes         | No                               |
| Toggle notes_visible| Yes         | No                               |

### Implementation

- Uses existing custom authorization: `require_admin!` before_action on write actions
- Custom scoping in index/show: admins see all workspace meetings, employees see only meetings where they are the `employee`
- Employee access to show is guarded — they can only view meetings assigned to them

## Routes

```ruby
resources :feedback_meetings, only: [:index, :new, :create, :show, :edit, :update, :destroy]
```

Flat under workspace scope, consistent with existing resources like projects and time_entries.

## Controller

`FeedbackMeetingsController` includes `WorkspaceScoped` concern.

### Actions

- **index** — Admin: all workspace meetings. Employee: only their meetings. Ordered by `scheduled_at` descending.
- **show** — Admin: any meeting. Employee: only their meeting. Notes hidden when `notes_visible` is false.
- **new/create** — Admin only. Form with employee select, title, datetime, notes, notes_visible checkbox.
- **edit/update** — Admin only. Same form as new.
- **destroy** — Admin only.

### Strong params

`title`, `scheduled_at`, `employee_id`, `notes`, `notes_visible`

## Model

### Associations

```ruby
class FeedbackMeeting < ApplicationRecord
  belongs_to :workspace
  belongs_to :creator, class_name: "User"
  belongs_to :employee, class_name: "User"
end
```

### Validations

- `title` — presence
- `scheduled_at` — presence
- `workspace` — presence
- `creator` — presence
- `employee` — presence

### Scopes

- `for_employee(user)` — where employee is the given user
- Default ordering by `scheduled_at` descending

## Views

All ERB + Tailwind CSS, consistent with existing app style.

### Index

Table listing meetings with columns: title, employee name, scheduled date/time. Admin sees all meetings with employee column. Employee sees only their meetings (no employee column needed).

### Show

Displays meeting details: title, scheduled date/time, employee name, creator name. Notes section visible to admin always; visible to employee only when `notes_visible` is true. When notes are hidden from employee, show a message like "Notes are not shared yet."

### New / Edit

Form fields:
- Employee select dropdown (list of workspace employees)
- Title text input
- Date/time picker for scheduled_at
- Notes textarea
- Notes visible checkbox

Admin-only views.

## Tests

### Model tests

- Validation: required fields
- Scope: `for_employee` returns correct records

### Controller tests

- Admin can CRUD meetings
- Employee can list and view only their own meetings
- Employee cannot create, edit, or destroy meetings
- Employee cannot see notes when `notes_visible` is false
- Employee can see notes when `notes_visible` is true

### Fixtures

Add feedback_meetings fixtures with workspace, creator, employee associations.
