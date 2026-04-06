# Feedback Meetings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow admins to create feedback meetings with employees, attach notes, and control note visibility per meeting.

**Architecture:** Single `FeedbackMeeting` model, workspace-scoped. `FeedbackMeetingsController` with mixed authorization — admin-only for writes, role-based scoping for reads. Follows the existing `ClientsController` CRUD pattern with added employee-scoping logic.

**Tech Stack:** Rails 8.1, ERB views, Tailwind CSS with M3 design tokens, Minitest, PostgreSQL

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `db/migrate/TIMESTAMP_create_feedback_meetings.rb` | Migration for feedback_meetings table |
| Create | `app/models/feedback_meeting.rb` | Model with validations, associations, scopes |
| Create | `app/controllers/feedback_meetings_controller.rb` | CRUD controller with role-based access |
| Create | `app/views/feedback_meetings/index.html.erb` | List of meetings |
| Create | `app/views/feedback_meetings/show.html.erb` | Meeting detail with notes |
| Create | `app/views/feedback_meetings/new.html.erb` | New meeting wrapper |
| Create | `app/views/feedback_meetings/edit.html.erb` | Edit meeting wrapper |
| Create | `app/views/feedback_meetings/_form.html.erb` | Shared form partial |
| Create | `test/fixtures/feedback_meetings.yml` | Test fixtures |
| Create | `test/models/feedback_meeting_test.rb` | Model unit tests |
| Create | `test/controllers/feedback_meetings_controller_test.rb` | Controller integration tests |
| Modify | `config/routes.rb:19` | Add feedback_meetings resource |
| Modify | `app/models/workspace.rb:9` | Add has_many :feedback_meetings |
| Modify | `app/models/user.rb:9` | Add has_many associations for created/assigned meetings |
| Modify | `app/views/layouts/application.html.erb:89` | Add nav link for Feedback Meetings |

---

### Task 1: Database Migration

**Files:**
- Create: `db/migrate/TIMESTAMP_create_feedback_meetings.rb`

- [ ] **Step 1: Generate the migration**

Run:
```bash
bin/rails generate migration CreateFeedbackMeetings
```

- [ ] **Step 2: Write the migration**

Open the generated file in `db/migrate/` and replace its content with:

```ruby
class CreateFeedbackMeetings < ActiveRecord::Migration[8.1]
  def change
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
  end
end
```

- [ ] **Step 3: Run the migration**

Run:
```bash
bin/rails db:migrate
```

Expected: Migration runs successfully. `db/schema.rb` now contains the `feedback_meetings` table.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/*_create_feedback_meetings.rb db/schema.rb
git commit -m "feat: add feedback_meetings migration"
```

---

### Task 2: FeedbackMeeting Model

**Files:**
- Create: `app/models/feedback_meeting.rb`
- Modify: `app/models/workspace.rb:9`
- Modify: `app/models/user.rb:9`
- Test: `test/models/feedback_meeting_test.rb`
- Create: `test/fixtures/feedback_meetings.yml`

- [ ] **Step 1: Create test fixtures**

Create `test/fixtures/feedback_meetings.yml`:

```yaml
one:
  workspace: one
  creator: one
  employee: two
  title: Q1 Performance Review
  scheduled_at: <%= 3.days.from_now.to_fs(:db) %>
  notes: Great performance this quarter.
  notes_visible: false

visible_notes:
  workspace: one
  creator: one
  employee: two
  title: Q2 Goal Setting
  scheduled_at: <%= 10.days.from_now.to_fs(:db) %>
  notes: Set goals for next quarter.
  notes_visible: true
```

- [ ] **Step 2: Write failing model tests**

Create `test/models/feedback_meeting_test.rb`:

```ruby
require "test_helper"

class FeedbackMeetingTest < ActiveSupport::TestCase
  test "valid feedback meeting" do
    meeting = feedback_meetings(:one)
    assert meeting.valid?
  end

  test "requires title" do
    meeting = feedback_meetings(:one)
    meeting.title = nil
    assert_not meeting.valid?
    assert_includes meeting.errors[:title], "can't be blank"
  end

  test "requires scheduled_at" do
    meeting = feedback_meetings(:one)
    meeting.scheduled_at = nil
    assert_not meeting.valid?
    assert_includes meeting.errors[:scheduled_at], "can't be blank"
  end

  test "requires workspace" do
    meeting = feedback_meetings(:one)
    meeting.workspace = nil
    assert_not meeting.valid?
  end

  test "requires creator" do
    meeting = feedback_meetings(:one)
    meeting.creator = nil
    assert_not meeting.valid?
  end

  test "requires employee" do
    meeting = feedback_meetings(:one)
    meeting.employee = nil
    assert_not meeting.valid?
  end

  test "for_employee scope returns only that employee's meetings" do
    employee = users(:two)
    meetings = FeedbackMeeting.for_employee(employee)
    assert meetings.all? { |m| m.employee_id == employee.id }
  end

  test "belongs to workspace" do
    meeting = feedback_meetings(:one)
    assert_equal workspaces(:one), meeting.workspace
  end

  test "belongs to creator" do
    meeting = feedback_meetings(:one)
    assert_equal users(:one), meeting.creator
  end

  test "belongs to employee" do
    meeting = feedback_meetings(:one)
    assert_equal users(:two), meeting.employee
  end

  test "default ordering is by scheduled_at descending" do
    meetings = FeedbackMeeting.recent
    dates = meetings.map(&:scheduled_at)
    assert_equal dates, dates.sort.reverse
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
bin/rails test test/models/feedback_meeting_test.rb
```

Expected: FAIL — `FeedbackMeeting` class not defined yet.

- [ ] **Step 4: Create the model**

Create `app/models/feedback_meeting.rb`:

```ruby
class FeedbackMeeting < ApplicationRecord
  belongs_to :workspace
  belongs_to :creator, class_name: "User"
  belongs_to :employee, class_name: "User"

  validates :title, presence: true
  validates :scheduled_at, presence: true

  scope :for_employee, ->(user) { where(employee: user) }
  scope :recent, -> { order(scheduled_at: :desc) }
end
```

- [ ] **Step 5: Add associations to Workspace model**

In `app/models/workspace.rb`, add after line 9 (after `has_many :chat_sessions, dependent: :destroy`):

```ruby
  has_many :feedback_meetings, dependent: :destroy
```

- [ ] **Step 6: Add associations to User model**

In `app/models/user.rb`, add after line 9 (after `has_many :chat_sessions, dependent: :destroy`):

```ruby
  has_many :created_feedback_meetings, class_name: "FeedbackMeeting", foreign_key: :creator_id, dependent: :destroy
  has_many :feedback_meetings, foreign_key: :employee_id, dependent: :destroy
```

- [ ] **Step 7: Run tests to verify they pass**

Run:
```bash
bin/rails test test/models/feedback_meeting_test.rb
```

Expected: All tests PASS.

- [ ] **Step 8: Commit**

```bash
git add app/models/feedback_meeting.rb app/models/workspace.rb app/models/user.rb test/models/feedback_meeting_test.rb test/fixtures/feedback_meetings.yml
git commit -m "feat: add FeedbackMeeting model with validations and scopes"
```

---

### Task 3: Routes

**Files:**
- Modify: `config/routes.rb:19`

- [ ] **Step 1: Add the route**

In `config/routes.rb`, add after line 19 (after `resources :clients`):

```ruby
  resources :feedback_meetings
```

- [ ] **Step 2: Verify routes exist**

Run:
```bash
bin/rails routes -g feedback_meetings
```

Expected: Output shows index, show, new, create, edit, update, destroy routes for feedback_meetings.

- [ ] **Step 3: Commit**

```bash
git add config/routes.rb
git commit -m "feat: add feedback_meetings routes"
```

---

### Task 4: Controller with Tests (TDD)

**Files:**
- Create: `app/controllers/feedback_meetings_controller.rb`
- Test: `test/controllers/feedback_meetings_controller_test.rb`

- [ ] **Step 1: Write failing controller tests**

Create `test/controllers/feedback_meetings_controller_test.rb`:

```ruby
require "test_helper"

class FeedbackMeetingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @employee = users(:two)
    @meeting = feedback_meetings(:one)
    @visible_meeting = feedback_meetings(:visible_notes)
  end

  # --- Admin tests ---

  test "admin can list all meetings" do
    sign_in_as(@admin)
    get feedback_meetings_path
    assert_response :success
  end

  test "admin can view any meeting" do
    sign_in_as(@admin)
    get feedback_meeting_path(@meeting)
    assert_response :success
  end

  test "admin can see notes regardless of notes_visible" do
    sign_in_as(@admin)
    get feedback_meeting_path(@meeting)
    assert_response :success
    assert_match "Great performance this quarter", response.body
  end

  test "admin can access new meeting form" do
    sign_in_as(@admin)
    get new_feedback_meeting_path
    assert_response :success
  end

  test "admin can create a meeting" do
    sign_in_as(@admin)
    assert_difference "FeedbackMeeting.count", 1 do
      post feedback_meetings_path, params: {
        feedback_meeting: {
          employee_id: @employee.id,
          title: "New Feedback Meeting",
          scheduled_at: 5.days.from_now,
          notes: "Discussion points",
          notes_visible: false
        }
      }
    end
    assert_redirected_to feedback_meetings_path
  end

  test "admin can access edit form" do
    sign_in_as(@admin)
    get edit_feedback_meeting_path(@meeting)
    assert_response :success
  end

  test "admin can update a meeting" do
    sign_in_as(@admin)
    patch feedback_meeting_path(@meeting), params: {
      feedback_meeting: { title: "Updated Title" }
    }
    assert_redirected_to feedback_meeting_path(@meeting)
    assert_equal "Updated Title", @meeting.reload.title
  end

  test "admin can toggle notes_visible" do
    sign_in_as(@admin)
    patch feedback_meeting_path(@meeting), params: {
      feedback_meeting: { notes_visible: true }
    }
    assert @meeting.reload.notes_visible
  end

  test "admin can destroy a meeting" do
    sign_in_as(@admin)
    assert_difference "FeedbackMeeting.count", -1 do
      delete feedback_meeting_path(@meeting)
    end
    assert_redirected_to feedback_meetings_path
  end

  # --- Employee tests ---

  test "employee can list only their meetings" do
    sign_in_as(@employee)
    get feedback_meetings_path
    assert_response :success
  end

  test "employee can view their own meeting" do
    sign_in_as(@employee)
    get feedback_meeting_path(@meeting)
    assert_response :success
  end

  test "employee cannot see notes when notes_visible is false" do
    sign_in_as(@employee)
    get feedback_meeting_path(@meeting)
    assert_response :success
    assert_no_match "Great performance this quarter", response.body
  end

  test "employee can see notes when notes_visible is true" do
    sign_in_as(@employee)
    get feedback_meeting_path(@visible_meeting)
    assert_response :success
    assert_match "Set goals for next quarter", response.body
  end

  test "employee cannot access new meeting form" do
    sign_in_as(@employee)
    get new_feedback_meeting_path
    assert_redirected_to root_path
  end

  test "employee cannot create a meeting" do
    sign_in_as(@employee)
    assert_no_difference "FeedbackMeeting.count" do
      post feedback_meetings_path, params: {
        feedback_meeting: {
          employee_id: @employee.id,
          title: "Unauthorized",
          scheduled_at: 5.days.from_now
        }
      }
    end
    assert_redirected_to root_path
  end

  test "employee cannot edit a meeting" do
    sign_in_as(@employee)
    get edit_feedback_meeting_path(@meeting)
    assert_redirected_to root_path
  end

  test "employee cannot update a meeting" do
    sign_in_as(@employee)
    patch feedback_meeting_path(@meeting), params: {
      feedback_meeting: { title: "Hacked" }
    }
    assert_redirected_to root_path
    assert_not_equal "Hacked", @meeting.reload.title
  end

  test "employee cannot destroy a meeting" do
    sign_in_as(@employee)
    assert_no_difference "FeedbackMeeting.count" do
      delete feedback_meeting_path(@meeting)
    end
    assert_redirected_to root_path
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
bin/rails test test/controllers/feedback_meetings_controller_test.rb
```

Expected: FAIL — `FeedbackMeetingsController` not defined.

- [ ] **Step 3: Create the controller**

Create `app/controllers/feedback_meetings_controller.rb`:

```ruby
class FeedbackMeetingsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!, only: %i[new create edit update destroy]
  before_action :set_feedback_meeting, only: %i[show edit update destroy]

  def index
    @feedback_meetings = scoped_meetings.recent.includes(:employee, :creator)
  end

  def show
  end

  def new
    @feedback_meeting = current_workspace.feedback_meetings.build
  end

  def create
    @feedback_meeting = current_workspace.feedback_meetings.build(feedback_meeting_params)
    @feedback_meeting.creator = current_user

    if @feedback_meeting.save
      redirect_to feedback_meetings_path, notice: "Feedback meeting created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @feedback_meeting.update(feedback_meeting_params)
      redirect_to feedback_meeting_path(@feedback_meeting), notice: "Feedback meeting updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @feedback_meeting.destroy
    redirect_to feedback_meetings_path, notice: "Feedback meeting deleted.", status: :see_other
  end

  private

  def scoped_meetings
    if current_user.admin_or_owner?(current_workspace)
      current_workspace.feedback_meetings
    else
      current_workspace.feedback_meetings.for_employee(current_user)
    end
  end

  def set_feedback_meeting
    @feedback_meeting = scoped_meetings.find(params[:id])
  end

  def feedback_meeting_params
    params.require(:feedback_meeting).permit(:title, :scheduled_at, :employee_id, :notes, :notes_visible)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
bin/rails test test/controllers/feedback_meetings_controller_test.rb
```

Expected: Tests will fail because views don't exist yet. That's expected — we'll create views in the next task. The tests that don't render views (create, update, destroy, redirects) should pass or fail with template errors.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/feedback_meetings_controller.rb test/controllers/feedback_meetings_controller_test.rb
git commit -m "feat: add FeedbackMeetingsController with role-based access"
```

---

### Task 5: Views

**Files:**
- Create: `app/views/feedback_meetings/index.html.erb`
- Create: `app/views/feedback_meetings/show.html.erb`
- Create: `app/views/feedback_meetings/new.html.erb`
- Create: `app/views/feedback_meetings/edit.html.erb`
- Create: `app/views/feedback_meetings/_form.html.erb`

- [ ] **Step 1: Create the index view**

Create `app/views/feedback_meetings/index.html.erb`:

```erb
<div class="space-y-5">
  <div class="flex justify-between items-center">
    <h1 class="text-2xl font-bold tracking-tight" style="color: var(--color-on-surface)">Feedback Meetings</h1>
    <% if current_user.admin_or_owner?(current_workspace) %>
      <%= link_to "New Meeting", new_feedback_meeting_path, class: "m3-btn m3-btn-filled" %>
    <% end %>
  </div>

  <div class="m3-card-outlined overflow-hidden">
    <table class="m3-table">
      <thead>
        <tr>
          <th>Title</th>
          <% if current_user.admin_or_owner?(current_workspace) %>
            <th>Employee</th>
          <% end %>
          <th>Scheduled</th>
          <% if current_user.admin_or_owner?(current_workspace) %>
            <th>Notes Shared</th>
            <th></th>
          <% end %>
        </tr>
      </thead>
      <tbody>
        <% @feedback_meetings.each do |meeting| %>
          <tr>
            <td class="font-medium">
              <%= link_to meeting.title, feedback_meeting_path(meeting), style: "color: var(--color-on-surface); text-decoration: none; transition: color 0.15s;", onmouseover: "this.style.color='var(--color-primary)'", onmouseout: "this.style.color='var(--color-on-surface)'" %>
            </td>
            <% if current_user.admin_or_owner?(current_workspace) %>
              <td>
                <div class="flex items-center gap-2">
                  <div class="m3-avatar m3-avatar-sm"><%= meeting.employee.name.first(2).upcase %></div>
                  <span class="text-sm" style="color: var(--color-on-surface)"><%= meeting.employee.name %></span>
                </div>
              </td>
            <% end %>
            <td class="text-sm" style="color: var(--color-on-surface-variant)"><%= meeting.scheduled_at.strftime("%b %d, %Y at %H:%M") %></td>
            <% if current_user.admin_or_owner?(current_workspace) %>
              <td>
                <span class="text-xs font-medium px-2 py-0.5 rounded-full" style="<%= meeting.notes_visible ? 'color: var(--color-primary); background: var(--color-primary-container)' : 'color: var(--color-outline); background: var(--color-surface-container)' %>">
                  <%= meeting.notes_visible ? "Yes" : "No" %>
                </span>
              </td>
              <td class="text-right">
                <div class="flex justify-end gap-1">
                  <%= link_to "Edit", edit_feedback_meeting_path(meeting), class: "m3-btn m3-btn-text m3-btn-sm" %>
                  <%= button_to "Delete", feedback_meeting_path(meeting), method: :delete,
                      class: "m3-btn m3-btn-text m3-btn-sm", style: "color: var(--color-error)",
                      data: { turbo_confirm: "Delete this feedback meeting?" } %>
                </div>
              </td>
            <% end %>
          </tr>
        <% end %>
        <% if @feedback_meetings.empty? %>
          <tr>
            <td colspan="<%= current_user.admin_or_owner?(current_workspace) ? 5 : 2 %>">
              <div class="empty-state">
                <div class="empty-state-icon">
                  <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M20.25 8.511c.884.284 1.5 1.128 1.5 2.097v4.286c0 1.136-.847 2.1-1.98 2.193-.34.027-.68.052-1.02.072v3.091l-3-3c-1.354 0-2.694-.055-4.02-.163a2.115 2.115 0 01-.825-.242m9.345-8.334a2.126 2.126 0 00-.476-.095 48.64 48.64 0 00-8.048 0c-1.131.094-1.976 1.057-1.976 2.192v4.286c0 .837.46 1.58 1.155 1.951m9.345-8.334V6.637c0-1.621-1.152-3.026-2.76-3.235A48.455 48.455 0 0011.25 3c-2.115 0-4.198.137-6.24.402-1.608.209-2.76 1.614-2.76 3.235v6.226c0 1.621 1.152 3.026 2.76 3.235.577.075 1.157.14 1.74.194V21l4.155-4.155" /></svg>
                </div>
                <p class="empty-state-title">No feedback meetings</p>
                <p class="empty-state-desc">
                  <% if current_user.admin_or_owner?(current_workspace) %>
                    Schedule a feedback meeting with a team member.
                  <% else %>
                    No feedback meetings scheduled for you yet.
                  <% end %>
                </p>
              </div>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>
</div>
```

- [ ] **Step 2: Create the show view**

Create `app/views/feedback_meetings/show.html.erb`:

```erb
<div class="space-y-4">
  <div class="flex justify-between items-center">
    <div>
      <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)"><%= @feedback_meeting.title %></h1>
      <p class="mt-1 text-sm" style="color: var(--color-on-surface-variant)">
        Scheduled for <%= @feedback_meeting.scheduled_at.strftime("%B %d, %Y at %H:%M") %>
      </p>
    </div>
    <div class="flex gap-2">
      <% if current_user.admin_or_owner?(current_workspace) %>
        <%= link_to "Edit", edit_feedback_meeting_path(@feedback_meeting), class: "m3-btn m3-btn-text" %>
      <% end %>
      <%= link_to "Back", feedback_meetings_path, class: "m3-btn m3-btn-text" %>
    </div>
  </div>

  <div class="m3-card-elevated p-6 space-y-4">
    <div class="flex gap-8">
      <div>
        <div class="text-xs font-medium mb-1" style="color: var(--color-outline)">Employee</div>
        <div class="flex items-center gap-2">
          <div class="m3-avatar m3-avatar-sm"><%= @feedback_meeting.employee.name.first(2).upcase %></div>
          <span class="text-sm font-medium" style="color: var(--color-on-surface)"><%= @feedback_meeting.employee.name %></span>
        </div>
      </div>
      <% if current_user.admin_or_owner?(current_workspace) %>
        <div>
          <div class="text-xs font-medium mb-1" style="color: var(--color-outline)">Created by</div>
          <span class="text-sm" style="color: var(--color-on-surface)"><%= @feedback_meeting.creator.name %></span>
        </div>
      <% end %>
    </div>

    <% show_notes = current_user.admin_or_owner?(current_workspace) || @feedback_meeting.notes_visible %>
    <div>
      <div class="flex items-center gap-2 mb-2">
        <div class="text-xs font-medium" style="color: var(--color-outline)">Notes</div>
        <% if current_user.admin_or_owner?(current_workspace) %>
          <span class="text-xs font-medium px-2 py-0.5 rounded-full" style="<%= @feedback_meeting.notes_visible ? 'color: var(--color-primary); background: var(--color-primary-container)' : 'color: var(--color-outline); background: var(--color-surface-container)' %>">
            <%= @feedback_meeting.notes_visible ? "Visible to employee" : "Hidden from employee" %>
          </span>
        <% end %>
      </div>
      <% if show_notes %>
        <% if @feedback_meeting.notes.present? %>
          <div class="text-sm whitespace-pre-wrap" style="color: var(--color-on-surface)"><%= @feedback_meeting.notes %></div>
        <% else %>
          <p class="text-sm" style="color: var(--color-on-surface-variant)">No notes yet.</p>
        <% end %>
      <% else %>
        <p class="text-sm" style="color: var(--color-on-surface-variant)">Notes are not shared yet.</p>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 3: Create the form partial**

Create `app/views/feedback_meetings/_form.html.erb`:

```erb
<%= form_with model: feedback_meeting, url: url, class: "space-y-4" do |f| %>
  <% if feedback_meeting.errors.any? %>
    <div class="m3-alert m3-alert-error">
      <ul><% feedback_meeting.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div class="space-y-1">
    <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Employee</label>
    <%= f.select :employee_id,
        current_workspace.workspace_memberships.where(role: [:employee, :admin, :owner]).includes(:user).map { |m| [m.user.name, m.user.id] },
        { prompt: "Select employee" },
        class: "m3-text-field w-full", required: true %>
  </div>

  <div class="space-y-1">
    <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Title</label>
    <%= f.text_field :title, class: "m3-text-field w-full", required: true %>
  </div>

  <div class="space-y-1">
    <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Scheduled At</label>
    <%= f.datetime_local_field :scheduled_at, class: "m3-text-field w-full", required: true %>
  </div>

  <div class="space-y-1">
    <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Notes</label>
    <%= f.text_area :notes, class: "m3-text-field w-full", rows: 6 %>
  </div>

  <label class="flex items-center gap-3 cursor-pointer">
    <%= f.check_box :notes_visible, class: "m3-checkbox" %>
    <span class="text-sm font-medium" style="color: var(--color-on-surface)">Share notes with employee</span>
  </label>

  <div class="flex gap-2">
    <%= f.submit class: "m3-btn m3-btn-filled" %>
    <%= link_to "Cancel", feedback_meetings_path, class: "m3-btn m3-btn-text" %>
  </div>
<% end %>
```

- [ ] **Step 4: Create the new view**

Create `app/views/feedback_meetings/new.html.erb`:

```erb
<div class="max-w-lg mx-auto">
  <h1 class="text-2xl font-bold mb-4" style="color: var(--color-on-surface)">New Feedback Meeting</h1>
  <div class="m3-card-elevated p-6">
    <%= render "form", feedback_meeting: @feedback_meeting, url: feedback_meetings_path %>
  </div>
</div>
```

- [ ] **Step 5: Create the edit view**

Create `app/views/feedback_meetings/edit.html.erb`:

```erb
<div class="max-w-lg mx-auto">
  <h1 class="text-2xl font-bold mb-4" style="color: var(--color-on-surface)">Edit Feedback Meeting</h1>
  <div class="m3-card-elevated p-6">
    <%= render "form", feedback_meeting: @feedback_meeting, url: feedback_meeting_path(@feedback_meeting) %>
  </div>
</div>
```

- [ ] **Step 6: Run all controller tests**

Run:
```bash
bin/rails test test/controllers/feedback_meetings_controller_test.rb
```

Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add app/views/feedback_meetings/
git commit -m "feat: add feedback meetings views"
```

---

### Task 6: Navigation Link

**Files:**
- Modify: `app/views/layouts/application.html.erb:89`

- [ ] **Step 1: Add the nav link**

In `app/views/layouts/application.html.erb`, find the `unless current_user.client_role?` section (line 91). This section already contains the Tags link and is visible to all non-client users (employees, admins, owners). Add the Feedback link **after** the Tags link (after line 96, before the closing `<% end %>` on line 97):

```erb
              <%= link_to feedback_meetings_path, class: "m3-nav-item #{request.path.start_with?('/feedback_meetings') ? 'active' : ''}" do %>
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M20.25 8.511c.884.284 1.5 1.128 1.5 2.097v4.286c0 1.136-.847 2.1-1.98 2.193-.34.027-.68.052-1.02.072v3.091l-3-3c-1.354 0-2.694-.055-4.02-.163a2.115 2.115 0 01-.825-.242m9.345-8.334a2.126 2.126 0 00-.476-.095 48.64 48.64 0 00-8.048 0c-1.131.094-1.976 1.057-1.976 2.192v4.286c0 .837.46 1.58 1.155 1.951m9.345-8.334V6.637c0-1.621-1.152-3.026-2.76-3.235A48.455 48.455 0 0011.25 3c-2.115 0-4.198.137-6.24.402-1.608.209-2.76 1.614-2.76 3.235v6.226c0 1.621 1.152 3.026 2.76 3.235.577.075 1.157.14 1.74.194V21l4.155-4.155" /></svg>
                <span>Feedback</span>
              <% end %>
```

This is placed in the `unless client_role?` block so employees, admins, and owners all see it. The controller handles scoping (admins see all, employees see only their own).

- [ ] **Step 2: Verify the nav renders**

Run:
```bash
bin/rails test test/controllers/feedback_meetings_controller_test.rb
```

Expected: All tests still pass.

- [ ] **Step 3: Commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "feat: add Feedback nav link for all authenticated users"
```

---

### Task 7: Run Full Test Suite

- [ ] **Step 1: Run all tests**

Run:
```bash
bin/rails test
```

Expected: All tests pass, including existing tests that haven't been modified.

- [ ] **Step 2: Verify the app starts**

Run:
```bash
bin/rails runner "puts FeedbackMeeting.count"
```

Expected: Outputs `0` (or a number if seeds exist). No errors.

- [ ] **Step 3: Final commit (if any uncommitted changes)**

```bash
git status
```

If clean, no commit needed. If there are any fixup changes, commit them.
