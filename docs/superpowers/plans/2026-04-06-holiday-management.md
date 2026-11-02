# Holiday Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a holiday/time-off management system with ledger-based balance tracking, request workflow, admin approval, and email notifications.

**Architecture:** Two new tables (`holiday_requests`, `holiday_balance_entries`) form a ledger-based balance system. Balance = SUM of all entries. Requests go through pending -> approved/cancelled workflow. Admin can manually adjust balances. A recurring job grants 20 days on January 1st.

**Tech Stack:** Rails 8.1, PostgreSQL/MySQL, Solid Queue (recurring jobs), Action Mailer, Minitest, Tailwind CSS + M3 design system, Stimulus.js

---

## File Structure

**Models:**
- Create: `app/models/holiday_request.rb` — request lifecycle (pending/approved/cancelled), approve!/cancel! methods
- Create: `app/models/holiday_balance_entry.rb` — ledger entry with type enum
- Create: `app/models/concerns/holidayable.rb` — User concern for balance calculation and associations
- Modify: `app/models/user.rb` — include Holidayable
- Modify: `app/models/workspace.rb` — add has_many associations

**Controllers:**
- Create: `app/controllers/holiday_requests_controller.rb` — CRUD + approve/cancel
- Create: `app/controllers/holiday_balance_entries_controller.rb` — ledger view + admin adjustments

**Mailers:**
- Create: `app/mailers/holiday_request_mailer.rb` — approved/cancelled emails
- Create: `app/views/holiday_request_mailer/approved.html.erb`
- Create: `app/views/holiday_request_mailer/approved.text.erb`
- Create: `app/views/holiday_request_mailer/cancelled.html.erb`
- Create: `app/views/holiday_request_mailer/cancelled.text.erb`

**Jobs:**
- Create: `app/jobs/holiday_yearly_grant_job.rb` — January 1st auto-grant

**Views:**
- Create: `app/views/holiday_requests/index.html.erb` — dashboard (employee + admin views)
- Create: `app/views/holiday_requests/new.html.erb` — request form
- Create: `app/views/holiday_balance_entries/index.html.erb` — ledger history
- Create: `app/views/holiday_balance_entries/new.html.erb` — admin adjustment form
- Modify: `app/views/layouts/application.html.erb:89` — add nav link

**Config:**
- Modify: `config/routes.rb` — add holiday routes
- Modify: `config/recurring.yml` — add yearly grant job schedule

**JavaScript:**
- Create: `app/javascript/controllers/business_days_controller.js` — compute business days on date change

**Tests:**
- Create: `test/models/holiday_request_test.rb`
- Create: `test/models/holiday_balance_entry_test.rb`
- Create: `test/controllers/holiday_requests_controller_test.rb`
- Create: `test/controllers/holiday_balance_entries_controller_test.rb`
- Create: `test/mailers/holiday_request_mailer_test.rb`
- Create: `test/jobs/holiday_yearly_grant_job_test.rb`
- Create: `test/fixtures/holiday_requests.yml`
- Create: `test/fixtures/holiday_balance_entries.yml`

**Migration:**
- Create: `db/migrate/TIMESTAMP_create_holiday_tables.rb`

---

### Task 1: Database Migration

**Files:**
- Create: `db/migrate/TIMESTAMP_create_holiday_tables.rb`

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration CreateHolidayTables`

- [ ] **Step 2: Write the migration**

Edit the generated migration file to contain:

```ruby
class CreateHolidayTables < ActiveRecord::Migration[8.1]
  def change
    create_table :holiday_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :business_days, null: false
      t.text :note
      t.integer :status, null: false, default: 0
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at

      t.timestamps
    end

    add_index :holiday_requests, [:workspace_id, :user_id]
    add_index :holiday_requests, [:workspace_id, :status]
    add_index :holiday_requests, [:user_id, :start_date, :end_date]

    create_table :holiday_balance_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.integer :entry_type, null: false
      t.integer :days, null: false
      t.text :note
      t.references :holiday_request, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :holiday_balance_entries, [:workspace_id, :user_id]
    add_index :holiday_balance_entries, [:user_id, :entry_type]
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: Migration runs successfully, schema.rb updated with both new tables.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/*_create_holiday_tables.rb db/schema.rb
git commit -m "feat: add holiday_requests and holiday_balance_entries tables"
```

---

### Task 2: HolidayBalanceEntry Model + Tests

**Files:**
- Create: `app/models/holiday_balance_entry.rb`
- Create: `test/models/holiday_balance_entry_test.rb`
- Create: `test/fixtures/holiday_balance_entries.yml`

- [ ] **Step 1: Create fixtures**

Create `test/fixtures/holiday_balance_entries.yml`:

```yaml
kacper_initial_grant:
  user: one
  workspace: one
  entry_type: 1
  days: 15
  note: "Initial balance for 2026"
  created_by: one

kacper_yearly_grant:
  user: one
  workspace: one
  entry_type: 0
  days: 20
  note: "Annual holiday grant for 2026"

other_user_grant:
  user: two
  workspace: one
  entry_type: 1
  days: 10
  note: "Initial balance for Other User"
  created_by: one
```

- [ ] **Step 2: Write the failing tests**

Create `test/models/holiday_balance_entry_test.rb`:

```ruby
require "test_helper"

class HolidayBalanceEntryTest < ActiveSupport::TestCase
  test "valid entry with all required fields" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :admin_adjustment,
      days: 5,
      note: "Extra days for Q4"
    )
    assert entry.valid?
  end

  test "invalid without days" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :yearly_grant
    )
    assert_not entry.valid?
    assert_includes entry.errors[:days], "can't be blank"
  end

  test "invalid with zero days" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :yearly_grant,
      days: 0
    )
    assert_not entry.valid?
  end

  test "admin_adjustment requires note" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :admin_adjustment,
      days: 5,
      note: nil
    )
    assert_not entry.valid?
    assert_includes entry.errors[:note], "is required for admin adjustments"
  end

  test "yearly_grant does not require note" do
    entry = HolidayBalanceEntry.new(
      user: users(:one),
      workspace: workspaces(:one),
      entry_type: :yearly_grant,
      days: 20
    )
    assert entry.valid?
  end

  test "entry_type enum values" do
    assert_equal 0, HolidayBalanceEntry.entry_types[:yearly_grant]
    assert_equal 1, HolidayBalanceEntry.entry_types[:admin_adjustment]
    assert_equal 2, HolidayBalanceEntry.entry_types[:deduction]
    assert_equal 3, HolidayBalanceEntry.entry_types[:reversal]
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/holiday_balance_entry_test.rb`
Expected: FAIL — `NameError: uninitialized constant HolidayBalanceEntry`

- [ ] **Step 4: Write the model**

Create `app/models/holiday_balance_entry.rb`:

```ruby
class HolidayBalanceEntry < ApplicationRecord
  belongs_to :user
  belongs_to :workspace
  belongs_to :holiday_request, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  enum :entry_type, { yearly_grant: 0, admin_adjustment: 1, deduction: 2, reversal: 3 }

  validates :days, presence: true, numericality: { other_than: 0 }
  validate :note_required_for_admin_adjustment

  private

  def note_required_for_admin_adjustment
    if admin_adjustment? && note.blank?
      errors.add(:note, "is required for admin adjustments")
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/holiday_balance_entry_test.rb`
Expected: All 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/models/holiday_balance_entry.rb test/models/holiday_balance_entry_test.rb test/fixtures/holiday_balance_entries.yml
git commit -m "feat: add HolidayBalanceEntry model with validations"
```

---

### Task 3: Holidayable Concern + User Integration

**Files:**
- Create: `app/models/concerns/holidayable.rb`
- Modify: `app/models/user.rb:1` — add `include Holidayable`
- Modify: `app/models/workspace.rb` — add has_many associations

- [ ] **Step 1: Write failing tests**

Add to `test/models/holiday_balance_entry_test.rb` (append at the end before the final `end`):

```ruby
  test "user holiday_balance sums all entries for workspace" do
    user = users(:one)
    workspace = workspaces(:one)
    # Fixtures: kacper_initial_grant (15) + kacper_yearly_grant (20) = 35
    assert_equal 35, user.holiday_balance(workspace)
  end

  test "user holiday_balance returns 0 with no entries" do
    user = users(:two)
    workspace = workspaces(:two)
    assert_equal 0, user.holiday_balance(workspace)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/holiday_balance_entry_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'holiday_balance' for User`

- [ ] **Step 3: Create the Holidayable concern**

Create `app/models/concerns/holidayable.rb`:

```ruby
module Holidayable
  extend ActiveSupport::Concern

  included do
    has_many :holiday_requests
    has_many :holiday_balance_entries
  end

  def holiday_balance(workspace)
    holiday_balance_entries.where(workspace: workspace).sum(:days)
  end
end
```

- [ ] **Step 4: Include concern in User model**

Modify `app/models/user.rb` — add after `has_many :chat_sessions, dependent: :destroy` (line 8):

```ruby
  include Holidayable
```

- [ ] **Step 5: Add associations to Workspace model**

Modify `app/models/workspace.rb` — add before `validates :name, presence: true` (line 11):

```ruby
  has_many :holiday_requests, dependent: :destroy
  has_many :holiday_balance_entries, dependent: :destroy
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/models/holiday_balance_entry_test.rb`
Expected: All 8 tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/models/concerns/holidayable.rb app/models/user.rb app/models/workspace.rb test/models/holiday_balance_entry_test.rb
git commit -m "feat: add Holidayable concern with balance calculation"
```

---

### Task 4: HolidayRequest Model + Tests

**Files:**
- Create: `app/models/holiday_request.rb`
- Create: `test/models/holiday_request_test.rb`
- Create: `test/fixtures/holiday_requests.yml`

- [ ] **Step 1: Create fixtures**

Create `test/fixtures/holiday_requests.yml`:

```yaml
kacper_pending:
  user: one
  workspace: one
  start_date: "2026-05-04"
  end_date: "2026-05-08"
  business_days: 5
  note: "Spring vacation"
  status: 0

kacper_approved:
  user: one
  workspace: one
  start_date: "2026-07-01"
  end_date: "2026-07-03"
  business_days: 3
  note: "Long weekend trip"
  status: 1
  reviewed_by: one

other_user_pending:
  user: two
  workspace: one
  start_date: "2026-06-15"
  end_date: "2026-06-19"
  business_days: 5
  note: "Summer break"
  status: 0
```

- [ ] **Step 2: Write failing tests**

Create `test/models/holiday_request_test.rb`:

```ruby
require "test_helper"

class HolidayRequestTest < ActiveSupport::TestCase
  test "valid request with all fields" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: 1.month.from_now.to_date,
      end_date: 1.month.from_now.to_date + 2.days,
      note: "Vacation"
    )
    assert request.valid?
    assert_equal 3, request.business_days
  end

  test "computes business_days excluding weekends" do
    # Monday May 4 to Friday May 8, 2026 = 5 business days
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 4),
      end_date: Date.new(2026, 5, 8)
    )
    request.valid?
    assert_equal 5, request.business_days
  end

  test "computes business_days for range spanning weekend" do
    # Monday May 4 to Monday May 11, 2026 = 6 business days (skip Sat 9, Sun 10)
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 4),
      end_date: Date.new(2026, 5, 11)
    )
    request.valid?
    assert_equal 6, request.business_days
  end

  test "single day request" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 4),
      end_date: Date.new(2026, 5, 4)
    )
    request.valid?
    assert_equal 1, request.business_days
  end

  test "invalid when start_date after end_date" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 8),
      end_date: Date.new(2026, 5, 4)
    )
    assert_not request.valid?
    assert_includes request.errors[:end_date], "must be on or after start date"
  end

  test "invalid when start_date in the past on create" do
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: 1.day.ago.to_date,
      end_date: Date.current
    )
    assert_not request.valid?
    assert_includes request.errors[:start_date], "can't be in the past"
  end

  test "invalid when overlapping with existing pending request" do
    existing = holiday_requests(:kacper_pending) # May 4-8
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 6),
      end_date: Date.new(2026, 5, 12)
    )
    assert_not request.valid?
    assert_includes request.errors[:base], "overlaps with an existing request"
  end

  test "invalid when overlapping with existing approved request" do
    existing = holiday_requests(:kacper_approved) # Jul 1-3
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 7, 2),
      end_date: Date.new(2026, 7, 4)
    )
    assert_not request.valid?
    assert_includes request.errors[:base], "overlaps with an existing request"
  end

  test "valid when overlapping with cancelled request" do
    cancelled = holiday_requests(:kacper_pending)
    cancelled.update_column(:status, 2) # cancelled
    request = HolidayRequest.new(
      user: users(:one),
      workspace: workspaces(:one),
      start_date: Date.new(2026, 5, 6),
      end_date: Date.new(2026, 5, 12)
    )
    assert request.valid?
  end

  test "invalid when insufficient balance" do
    user = users(:two)
    workspace = workspaces(:one)
    # other_user has 10 days balance (from fixture), but pending request for 5 already
    # Request 6 more days — balance is 10, but 5 are pending, so effective = 5
    request = HolidayRequest.new(
      user: user,
      workspace: workspace,
      start_date: 2.months.from_now.beginning_of_week.to_date,
      end_date: 2.months.from_now.beginning_of_week.to_date + 5.days,
      note: "Too many days"
    )
    assert_not request.valid?
    assert_includes request.errors[:base], "insufficient holiday balance"
  end

  test "status enum values" do
    assert_equal 0, HolidayRequest.statuses[:pending]
    assert_equal 1, HolidayRequest.statuses[:approved]
    assert_equal 2, HolidayRequest.statuses[:cancelled]
  end

  test "approve! creates deduction entry and sends email" do
    request = holiday_requests(:kacper_pending)
    admin = users(:one)

    assert_difference "HolidayBalanceEntry.count", 1 do
      assert_emails 1 do
        request.approve!(admin)
      end
    end

    assert request.approved?
    assert_equal admin, request.reviewed_by
    assert_not_nil request.reviewed_at

    entry = request.holiday_balance_entries.last
    assert_equal "deduction", entry.entry_type
    assert_equal(-request.business_days, entry.days)
  end

  test "cancel! pending request does not create reversal" do
    request = holiday_requests(:kacper_pending)
    admin = users(:one)

    assert_no_difference "HolidayBalanceEntry.count" do
      assert_emails 1 do
        request.cancel!(admin)
      end
    end

    assert request.cancelled?
    assert_equal admin, request.reviewed_by
  end

  test "cancel! approved request creates reversal entry" do
    request = holiday_requests(:kacper_approved)
    admin = users(:one)
    # First add a deduction so there's something to reverse
    request.holiday_balance_entries.create!(
      user: request.user,
      workspace: request.workspace,
      entry_type: :deduction,
      days: -request.business_days
    )

    assert_difference "HolidayBalanceEntry.count", 1 do
      assert_emails 1 do
        request.cancel!(admin)
      end
    end

    assert request.cancelled?
    reversal = request.holiday_balance_entries.reversal.last
    assert_equal request.business_days, reversal.days
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/models/holiday_request_test.rb`
Expected: FAIL — `NameError: uninitialized constant HolidayRequest`

- [ ] **Step 4: Write the model**

Create `app/models/holiday_request.rb`:

```ruby
class HolidayRequest < ApplicationRecord
  belongs_to :user
  belongs_to :workspace
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :holiday_balance_entries

  enum :status, { pending: 0, approved: 1, cancelled: 2 }

  validates :start_date, :end_date, presence: true
  validate :end_date_after_start_date
  validate :start_date_not_in_past, on: :create
  validate :no_overlapping_requests, on: :create
  validate :sufficient_balance, on: :create

  before_validation :compute_business_days

  scope :active, -> { where(status: [:pending, :approved]) }

  def approve!(admin)
    transaction do
      update!(
        status: :approved,
        reviewed_by: admin,
        reviewed_at: Time.current
      )
      holiday_balance_entries.create!(
        user: user,
        workspace: workspace,
        entry_type: :deduction,
        days: -business_days
      )
    end
    HolidayRequestMailer.approved(self).deliver_later
  end

  def cancel!(admin)
    was_approved = approved?
    transaction do
      update!(
        status: :cancelled,
        reviewed_by: admin,
        reviewed_at: Time.current
      )
      if was_approved
        holiday_balance_entries.create!(
          user: user,
          workspace: workspace,
          entry_type: :reversal,
          days: business_days
        )
      end
    end
    HolidayRequestMailer.cancelled(self).deliver_later
  end

  private

  def compute_business_days
    return unless start_date.present? && end_date.present? && start_date <= end_date
    self.business_days = (start_date..end_date).count { |d| !d.saturday? && !d.sunday? }
  end

  def end_date_after_start_date
    return unless start_date.present? && end_date.present?
    if end_date < start_date
      errors.add(:end_date, "must be on or after start date")
    end
  end

  def start_date_not_in_past
    return unless start_date.present?
    if start_date < Date.current
      errors.add(:start_date, "can't be in the past")
    end
  end

  def no_overlapping_requests
    return unless start_date.present? && end_date.present?
    overlapping = HolidayRequest
      .where(user: user, workspace: workspace)
      .where(status: [:pending, :approved])
      .where("start_date <= ? AND end_date >= ?", end_date, start_date)
    overlapping = overlapping.where.not(id: id) if persisted?
    if overlapping.exists?
      errors.add(:base, "overlaps with an existing request")
    end
  end

  def sufficient_balance
    return unless user.present? && workspace.present? && business_days.present?
    pending_days = HolidayRequest
      .where(user: user, workspace: workspace, status: :pending)
      .sum(:business_days)
    available = user.holiday_balance(workspace) - pending_days
    if available < business_days
      errors.add(:base, "insufficient holiday balance (#{available} days available, #{business_days} requested)")
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/models/holiday_request_test.rb`
Expected: Some tests will fail because HolidayRequestMailer doesn't exist yet. That's expected — we'll create it in the next task.

- [ ] **Step 6: Commit**

```bash
git add app/models/holiday_request.rb test/models/holiday_request_test.rb test/fixtures/holiday_requests.yml
git commit -m "feat: add HolidayRequest model with validations, approve!, cancel!"
```

---

### Task 5: HolidayRequestMailer

**Files:**
- Create: `app/mailers/holiday_request_mailer.rb`
- Create: `app/views/holiday_request_mailer/approved.html.erb`
- Create: `app/views/holiday_request_mailer/approved.text.erb`
- Create: `app/views/holiday_request_mailer/cancelled.html.erb`
- Create: `app/views/holiday_request_mailer/cancelled.text.erb`
- Create: `test/mailers/holiday_request_mailer_test.rb`

- [ ] **Step 1: Write failing mailer tests**

Create `test/mailers/holiday_request_mailer_test.rb`:

```ruby
require "test_helper"

class HolidayRequestMailerTest < ActionMailer::TestCase
  test "approved email" do
    request = holiday_requests(:kacper_pending)
    request.update_columns(status: 1, reviewed_by_id: users(:one).id, reviewed_at: Time.current)

    mail = HolidayRequestMailer.approved(request)

    assert_equal "Your time off request has been approved", mail.subject
    assert_equal [request.user.email_address], mail.to
    assert_match "May 4", mail.body.encoded
    assert_match "May 8", mail.body.encoded
    assert_match "5 days", mail.body.encoded
  end

  test "cancelled email" do
    request = holiday_requests(:kacper_approved)
    request.update_columns(status: 2, reviewed_by_id: users(:one).id, reviewed_at: Time.current)

    mail = HolidayRequestMailer.cancelled(request)

    assert_equal "Your time off request has been cancelled", mail.subject
    assert_equal [request.user.email_address], mail.to
    assert_match "Jul 1", mail.body.encoded
    assert_match "Jul 3", mail.body.encoded
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/mailers/holiday_request_mailer_test.rb`
Expected: FAIL — `NameError: uninitialized constant HolidayRequestMailer`

- [ ] **Step 3: Create the mailer**

Create `app/mailers/holiday_request_mailer.rb`:

```ruby
class HolidayRequestMailer < ApplicationMailer
  def approved(holiday_request)
    @holiday_request = holiday_request
    @user = holiday_request.user
    @reviewer = holiday_request.reviewed_by
    mail(
      to: @user.email_address,
      subject: "Your time off request has been approved"
    )
  end

  def cancelled(holiday_request)
    @holiday_request = holiday_request
    @user = holiday_request.user
    @reviewer = holiday_request.reviewed_by
    mail(
      to: @user.email_address,
      subject: "Your time off request has been cancelled"
    )
  end
end
```

- [ ] **Step 4: Create the email templates**

Create `app/views/holiday_request_mailer/approved.html.erb`:

```erb
<p>Hi <%= @user.name %>,</p>

<p>Your time off request has been <strong>approved</strong> by <%= @reviewer.name %>.</p>

<p>
  <strong>Dates:</strong> <%= @holiday_request.start_date.strftime("%b %-d, %Y") %> &ndash; <%= @holiday_request.end_date.strftime("%b %-d, %Y") %><br>
  <strong>Duration:</strong> <%= @holiday_request.business_days %> days
</p>

<% if @holiday_request.note.present? %>
  <p><strong>Note:</strong> <%= @holiday_request.note %></p>
<% end %>
```

Create `app/views/holiday_request_mailer/approved.text.erb`:

```erb
Hi <%= @user.name %>,

Your time off request has been approved by <%= @reviewer.name %>.

Dates: <%= @holiday_request.start_date.strftime("%b %-d, %Y") %> - <%= @holiday_request.end_date.strftime("%b %-d, %Y") %>
Duration: <%= @holiday_request.business_days %> days
<% if @holiday_request.note.present? %>
Note: <%= @holiday_request.note %>
<% end %>
```

Create `app/views/holiday_request_mailer/cancelled.html.erb`:

```erb
<p>Hi <%= @user.name %>,</p>

<p>Your time off request has been <strong>cancelled</strong> by <%= @reviewer.name %>.</p>

<p>
  <strong>Dates:</strong> <%= @holiday_request.start_date.strftime("%b %-d, %Y") %> &ndash; <%= @holiday_request.end_date.strftime("%b %-d, %Y") %><br>
  <strong>Duration:</strong> <%= @holiday_request.business_days %> days
</p>

<% if @holiday_request.note.present? %>
  <p><strong>Note:</strong> <%= @holiday_request.note %></p>
<% end %>
```

Create `app/views/holiday_request_mailer/cancelled.text.erb`:

```erb
Hi <%= @user.name %>,

Your time off request has been cancelled by <%= @reviewer.name %>.

Dates: <%= @holiday_request.start_date.strftime("%b %-d, %Y") %> - <%= @holiday_request.end_date.strftime("%b %-d, %Y") %>
Duration: <%= @holiday_request.business_days %> days
<% if @holiday_request.note.present? %>
Note: <%= @holiday_request.note %>
<% end %>
```

- [ ] **Step 5: Run mailer tests**

Run: `bin/rails test test/mailers/holiday_request_mailer_test.rb`
Expected: All 2 tests pass.

- [ ] **Step 6: Now run the HolidayRequest model tests too**

Run: `bin/rails test test/models/holiday_request_test.rb`
Expected: All tests pass now that the mailer exists.

- [ ] **Step 7: Commit**

```bash
git add app/mailers/holiday_request_mailer.rb app/views/holiday_request_mailer/ test/mailers/holiday_request_mailer_test.rb
git commit -m "feat: add HolidayRequestMailer with approved/cancelled emails"
```

---

### Task 6: Routes

**Files:**
- Modify: `config/routes.rb`

- [ ] **Step 1: Add holiday routes**

In `config/routes.rb`, add after the `resources :tags` line (line 30):

```ruby
  resources :holiday_requests, only: [:index, :new, :create] do
    member do
      patch :approve
      patch :cancel
    end
  end

  resources :holiday_balance_entries, only: [:index, :new, :create]
```

- [ ] **Step 2: Verify routes**

Run: `bin/rails routes | grep holiday`
Expected: Should show routes for holiday_requests (index, new, create, approve, cancel) and holiday_balance_entries (index, new, create).

- [ ] **Step 3: Commit**

```bash
git add config/routes.rb
git commit -m "feat: add holiday request and balance entry routes"
```

---

### Task 7: HolidayRequestsController + Tests

**Files:**
- Create: `app/controllers/holiday_requests_controller.rb`
- Create: `test/controllers/holiday_requests_controller_test.rb`

- [ ] **Step 1: Write failing controller tests**

Create `test/controllers/holiday_requests_controller_test.rb`:

```ruby
require "test_helper"

class HolidayRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "index shows holiday requests" do
    get holiday_requests_path
    assert_response :success
  end

  test "index as employee shows own requests" do
    sign_in_as(users(:two))
    get holiday_requests_path
    assert_response :success
  end

  test "new shows request form" do
    get new_holiday_request_path
    assert_response :success
  end

  test "create with valid params" do
    start_date = 1.month.from_now.beginning_of_week.to_date
    end_date = start_date + 4.days

    assert_difference "HolidayRequest.count", 1 do
      post holiday_requests_path, params: {
        holiday_request: {
          start_date: start_date,
          end_date: end_date,
          note: "Vacation time"
        }
      }
    end
    assert_redirected_to holiday_requests_path
  end

  test "create with insufficient balance shows error" do
    # User one has 35 days balance, but let's exhaust it
    start_date = 3.months.from_now.beginning_of_week.to_date
    end_date = start_date + 200.days # way too many

    assert_no_difference "HolidayRequest.count" do
      post holiday_requests_path, params: {
        holiday_request: {
          start_date: start_date,
          end_date: end_date,
          note: "Too long"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "approve as admin" do
    request = holiday_requests(:other_user_pending)

    patch approve_holiday_request_path(request)
    assert_redirected_to holiday_requests_path

    request.reload
    assert request.approved?
    assert_equal users(:one), request.reviewed_by
  end

  test "approve requires admin" do
    sign_in_as(users(:two)) # employee
    request = holiday_requests(:kacper_pending)

    patch approve_holiday_request_path(request)
    assert_redirected_to root_path
  end

  test "cancel as admin" do
    request = holiday_requests(:other_user_pending)

    patch cancel_holiday_request_path(request)
    assert_redirected_to holiday_requests_path

    request.reload
    assert request.cancelled?
  end

  test "cancel requires admin" do
    sign_in_as(users(:two)) # employee
    request = holiday_requests(:kacper_pending)

    patch cancel_holiday_request_path(request)
    assert_redirected_to root_path
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: FAIL — routing errors or `NameError`

- [ ] **Step 3: Write the controller**

Create `app/controllers/holiday_requests_controller.rb`:

```ruby
class HolidayRequestsController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!
  before_action :require_admin!, only: [:approve, :cancel]
  before_action :set_holiday_request, only: [:approve, :cancel]

  def index
    @balance = current_user.holiday_balance(current_workspace)

    if current_user.admin_or_owner?(current_workspace)
      @pending_requests = current_workspace.holiday_requests
        .pending
        .includes(:user)
        .order(start_date: :asc)
      @all_requests = current_workspace.holiday_requests
        .includes(:user, :reviewed_by)
        .order(created_at: :desc)
    end

    @my_requests = current_user.holiday_requests
      .where(workspace: current_workspace)
      .order(start_date: :desc)

    @team_upcoming = upcoming_team_holidays
  end

  def new
    @holiday_request = current_workspace.holiday_requests.build(user: current_user)
    @balance = current_user.holiday_balance(current_workspace)
  end

  def create
    @holiday_request = current_workspace.holiday_requests.build(holiday_request_params)
    @holiday_request.user = current_user

    if @holiday_request.save
      redirect_to holiday_requests_path, notice: "Time off request submitted."
    else
      @balance = current_user.holiday_balance(current_workspace)
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    @holiday_request.approve!(current_user)
    redirect_to holiday_requests_path, notice: "Request approved."
  end

  def cancel
    @holiday_request.cancel!(current_user)
    redirect_to holiday_requests_path, notice: "Request cancelled."
  end

  private

  def set_holiday_request
    @holiday_request = current_workspace.holiday_requests.find(params[:id])
  end

  def holiday_request_params
    params.require(:holiday_request).permit(:start_date, :end_date, :note)
  end

  def upcoming_team_holidays
    project_ids = current_user.project_memberships
      .joins(:project)
      .where(projects: { workspace_id: current_workspace.id })
      .pluck(:project_id)

    teammate_ids = ProjectMembership
      .where(project_id: project_ids)
      .where.not(user_id: current_user.id)
      .distinct
      .pluck(:user_id)

    HolidayRequest
      .where(workspace: current_workspace, user_id: teammate_ids, status: :approved)
      .where("end_date >= ?", Date.current)
      .includes(:user)
      .order(start_date: :asc)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: Tests will fail because views don't exist yet. That's expected — we'll create views in a later task. The controller logic is correct.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/holiday_requests_controller.rb test/controllers/holiday_requests_controller_test.rb
git commit -m "feat: add HolidayRequestsController with approve/cancel actions"
```

---

### Task 8: HolidayBalanceEntriesController + Tests

**Files:**
- Create: `app/controllers/holiday_balance_entries_controller.rb`
- Create: `test/controllers/holiday_balance_entries_controller_test.rb`

- [ ] **Step 1: Write failing controller tests**

Create `test/controllers/holiday_balance_entries_controller_test.rb`:

```ruby
require "test_helper"

class HolidayBalanceEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one)) # owner/admin
  end

  test "index shows balance entries for a user" do
    get holiday_balance_entries_path(user_id: users(:one).id)
    assert_response :success
  end

  test "index for own entries as employee" do
    sign_in_as(users(:two))
    get holiday_balance_entries_path
    assert_response :success
  end

  test "new shows adjustment form for admin" do
    get new_holiday_balance_entry_path(user_id: users(:two).id)
    assert_response :success
  end

  test "new requires admin" do
    sign_in_as(users(:two))
    get new_holiday_balance_entry_path(user_id: users(:one).id)
    assert_redirected_to root_path
  end

  test "create admin adjustment" do
    assert_difference "HolidayBalanceEntry.count", 1 do
      post holiday_balance_entries_path, params: {
        holiday_balance_entry: {
          user_id: users(:two).id,
          days: 5,
          note: "Bonus days for extra work"
        }
      }
    end
    assert_redirected_to holiday_balance_entries_path(user_id: users(:two).id)

    entry = HolidayBalanceEntry.last
    assert_equal "admin_adjustment", entry.entry_type
    assert_equal 5, entry.days
    assert_equal users(:one), entry.created_by
  end

  test "create requires admin" do
    sign_in_as(users(:two))
    assert_no_difference "HolidayBalanceEntry.count" do
      post holiday_balance_entries_path, params: {
        holiday_balance_entry: {
          user_id: users(:one).id,
          days: 5,
          note: "Trying to hack"
        }
      }
    end
    assert_redirected_to root_path
  end

  test "create with missing note fails" do
    assert_no_difference "HolidayBalanceEntry.count" do
      post holiday_balance_entries_path, params: {
        holiday_balance_entry: {
          user_id: users(:two).id,
          days: 5,
          note: ""
        }
      }
    end
    assert_response :unprocessable_entity
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/holiday_balance_entries_controller_test.rb`
Expected: FAIL — routing/controller errors

- [ ] **Step 3: Write the controller**

Create `app/controllers/holiday_balance_entries_controller.rb`:

```ruby
class HolidayBalanceEntriesController < ApplicationController
  include WorkspaceScoped

  before_action :require_employee!
  before_action :require_admin!, only: [:new, :create]

  def index
    if current_user.admin_or_owner?(current_workspace) && params[:user_id].present?
      @target_user = User.find(params[:user_id])
    else
      @target_user = current_user
    end

    @entries = HolidayBalanceEntry
      .where(user: @target_user, workspace: current_workspace)
      .includes(:created_by, :holiday_request)
      .order(created_at: :desc)

    @balance = @target_user.holiday_balance(current_workspace)

    if params[:year].present?
      year = params[:year].to_i
      @entries = @entries.where(created_at: Date.new(year)..Date.new(year).end_of_year)
    end
  end

  def new
    @target_user = User.find(params[:user_id])
    @entry = HolidayBalanceEntry.new
    @balance = @target_user.holiday_balance(current_workspace)
  end

  def create
    @target_user = User.find(entry_params[:user_id])
    @entry = HolidayBalanceEntry.new(
      user: @target_user,
      workspace: current_workspace,
      entry_type: :admin_adjustment,
      days: entry_params[:days],
      note: entry_params[:note],
      created_by: current_user
    )

    if @entry.save
      redirect_to holiday_balance_entries_path(user_id: @target_user.id),
        notice: "Balance adjusted by #{@entry.days} days."
    else
      @balance = @target_user.holiday_balance(current_workspace)
      render :new, status: :unprocessable_entity
    end
  end

  private

  def entry_params
    params.require(:holiday_balance_entry).permit(:user_id, :days, :note)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/controllers/holiday_balance_entries_controller_test.rb`
Expected: Tests will fail because views don't exist yet — that's expected.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/holiday_balance_entries_controller.rb test/controllers/holiday_balance_entries_controller_test.rb
git commit -m "feat: add HolidayBalanceEntriesController for ledger and adjustments"
```

---

### Task 9: HolidayYearlyGrantJob + Tests

**Files:**
- Create: `app/jobs/holiday_yearly_grant_job.rb`
- Create: `test/jobs/holiday_yearly_grant_job_test.rb`
- Modify: `config/recurring.yml`

- [ ] **Step 1: Write failing tests**

Create `test/jobs/holiday_yearly_grant_job_test.rb`:

```ruby
require "test_helper"

class HolidayYearlyGrantJobTest < ActiveSupport::TestCase
  test "creates yearly grant for all active members" do
    assert_difference "HolidayBalanceEntry.count", 2 do
      HolidayYearlyGrantJob.perform_now
    end

    entry = HolidayBalanceEntry.where(user: users(:one), entry_type: :yearly_grant).last
    assert_equal 20, entry.days
    assert_match "Annual holiday grant for #{Date.current.year}", entry.note
  end

  test "skips client role members" do
    # Add a client membership
    workspaces(:one).workspace_memberships.create!(user: User.create!(
      name: "Client User",
      email_address: "client@example.com",
      password: "password123"
    ), role: :client)

    count_before = HolidayBalanceEntry.yearly_grant.count
    HolidayYearlyGrantJob.perform_now
    # Should only create for 2 existing members (one=owner, two=employee), not the client
    assert_equal count_before + 2, HolidayBalanceEntry.yearly_grant.count
  end

  test "idempotent — does not duplicate grants" do
    HolidayYearlyGrantJob.perform_now
    initial_count = HolidayBalanceEntry.yearly_grant.where(
      "created_at >= ?", Date.current.beginning_of_year
    ).count

    HolidayYearlyGrantJob.perform_now
    final_count = HolidayBalanceEntry.yearly_grant.where(
      "created_at >= ?", Date.current.beginning_of_year
    ).count

    assert_equal initial_count, final_count
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/jobs/holiday_yearly_grant_job_test.rb`
Expected: FAIL — `NameError: uninitialized constant HolidayYearlyGrantJob`

- [ ] **Step 3: Write the job**

Create `app/jobs/holiday_yearly_grant_job.rb`:

```ruby
class HolidayYearlyGrantJob < ApplicationJob
  queue_as :default

  def perform
    year = Date.current.year

    WorkspaceMembership.where(role: [:employee, :admin, :owner]).includes(:user, :workspace).find_each do |membership|
      already_granted = HolidayBalanceEntry.exists?(
        user: membership.user,
        workspace: membership.workspace,
        entry_type: :yearly_grant,
        created_at: Date.new(year).beginning_of_year..Date.new(year).end_of_year
      )

      next if already_granted

      HolidayBalanceEntry.create!(
        user: membership.user,
        workspace: membership.workspace,
        entry_type: :yearly_grant,
        days: 20,
        note: "Annual holiday grant for #{year}"
      )
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/jobs/holiday_yearly_grant_job_test.rb`
Expected: All 3 tests pass.

- [ ] **Step 5: Add to recurring schedule**

Modify `config/recurring.yml` — add after the `jira_sync` entry:

```yaml
  holiday_yearly_grant:
    class: HolidayYearlyGrantJob
    schedule: at 12am on January 1
```

- [ ] **Step 6: Commit**

```bash
git add app/jobs/holiday_yearly_grant_job.rb test/jobs/holiday_yearly_grant_job_test.rb config/recurring.yml
git commit -m "feat: add HolidayYearlyGrantJob for annual 20-day grant"
```

---

### Task 10: Holiday Requests Views

**Files:**
- Create: `app/views/holiday_requests/index.html.erb`
- Create: `app/views/holiday_requests/new.html.erb`
- Create: `app/javascript/controllers/business_days_controller.js`

- [ ] **Step 1: Create the index view**

Create `app/views/holiday_requests/index.html.erb`:

```erb
<div class="space-y-6">
  <div class="flex justify-between items-center">
    <h1 class="text-2xl font-bold tracking-tight" style="color: var(--color-on-surface)">Holidays</h1>
    <div class="flex items-center gap-3">
      <div class="text-right">
        <div class="text-2xl font-bold" style="color: var(--color-primary)"><%= @balance %></div>
        <div class="text-xs" style="color: var(--color-outline)">days remaining</div>
      </div>
      <%= link_to "Request Time Off", new_holiday_request_path, class: "m3-btn m3-btn-filled" %>
    </div>
  </div>

  <%# Admin: Pending Requests %>
  <% if current_user.admin_or_owner?(current_workspace) && @pending_requests&.any? %>
    <div class="space-y-2">
      <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">Pending Approval</h2>
      <div class="m3-card-outlined overflow-hidden">
        <% @pending_requests.each do |request| %>
          <div class="flex items-center justify-between p-4 border-b" style="border-color: var(--color-outline-variant)">
            <div class="flex items-center gap-3">
              <div class="m3-avatar m3-avatar-sm"><%= request.user.name.first(2).upcase %></div>
              <div>
                <div class="text-sm font-medium" style="color: var(--color-on-surface)"><%= request.user.name %></div>
                <div class="text-xs" style="color: var(--color-outline)">
                  <%= request.start_date.strftime("%b %-d") %> &ndash; <%= request.end_date.strftime("%b %-d, %Y") %>
                  &middot; <%= request.business_days %> days
                </div>
                <% if request.note.present? %>
                  <div class="text-xs mt-0.5" style="color: var(--color-on-surface-variant)"><%= request.note %></div>
                <% end %>
              </div>
            </div>
            <div class="flex gap-2">
              <%= button_to "Approve", approve_holiday_request_path(request), method: :patch, class: "m3-btn m3-btn-filled m3-btn-sm" %>
              <%= button_to "Cancel", cancel_holiday_request_path(request), method: :patch, class: "m3-btn m3-btn-outlined m3-btn-sm",
                  data: { turbo_confirm: "Cancel this request?" } %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
  <% end %>

  <%# My Requests %>
  <div class="space-y-2">
    <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">My Requests</h2>
    <% if @my_requests.any? %>
      <div class="m3-card-outlined overflow-hidden">
        <% @my_requests.each do |request| %>
          <div class="flex items-center justify-between p-4 border-b" style="border-color: var(--color-outline-variant)">
            <div>
              <div class="text-sm font-medium" style="color: var(--color-on-surface)">
                <%= request.start_date.strftime("%b %-d") %> &ndash; <%= request.end_date.strftime("%b %-d, %Y") %>
                &middot; <%= request.business_days %> days
              </div>
              <% if request.note.present? %>
                <div class="text-xs mt-0.5" style="color: var(--color-on-surface-variant)"><%= request.note %></div>
              <% end %>
            </div>
            <span class="text-[10px] font-semibold uppercase tracking-wider px-2.5 py-1 rounded-full"
                  style="<%= holiday_status_style(request.status) %>">
              <%= request.status %>
            </span>
          </div>
        <% end %>
      </div>
    <% else %>
      <div class="m3-card-outlined p-6 text-center">
        <p class="text-sm" style="color: var(--color-outline)">No time off requests yet.</p>
      </div>
    <% end %>
  </div>

  <%# Team upcoming holidays %>
  <% if @team_upcoming.any? %>
    <div class="space-y-2">
      <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">Team Time Off</h2>
      <div class="m3-card-outlined overflow-hidden">
        <% @team_upcoming.each do |request| %>
          <div class="flex items-center gap-3 p-4 border-b" style="border-color: var(--color-outline-variant)">
            <div class="m3-avatar m3-avatar-sm"><%= request.user.name.first(2).upcase %></div>
            <div>
              <div class="text-sm font-medium" style="color: var(--color-on-surface)"><%= request.user.name %></div>
              <div class="text-xs" style="color: var(--color-outline)">
                <%= request.start_date.strftime("%b %-d") %> &ndash; <%= request.end_date.strftime("%b %-d, %Y") %>
                &middot; <%= request.business_days %> days
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
  <% end %>

  <%# Balance History Link %>
  <div class="text-center">
    <%= link_to "View balance history", holiday_balance_entries_path, class: "text-sm font-medium", style: "color: var(--color-primary)" %>
    <% if current_user.admin_or_owner?(current_workspace) %>
      &middot;
      <%= link_to "Manage team balances", holiday_balance_entries_path(view: "team"), class: "text-sm font-medium", style: "color: var(--color-primary)" %>
    <% end %>
  </div>
</div>
```

- [ ] **Step 2: Create the helper for status badges**

Create `app/helpers/holiday_requests_helper.rb`:

```ruby
module HolidayRequestsHelper
  def holiday_status_style(status)
    case status
    when "pending"
      "background: color-mix(in srgb, var(--color-tertiary) 15%, transparent); color: var(--color-tertiary)"
    when "approved"
      "background: color-mix(in srgb, #4CAF50 15%, transparent); color: #4CAF50"
    when "cancelled"
      "background: color-mix(in srgb, var(--color-error) 15%, transparent); color: var(--color-error)"
    end
  end
end
```

- [ ] **Step 3: Create the new request form**

Create `app/views/holiday_requests/new.html.erb`:

```erb
<div class="max-w-lg mx-auto space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)">Request Time Off</h1>
    <%= link_to "Back", holiday_requests_path, class: "m3-btn m3-btn-text" %>
  </div>

  <div class="text-right">
    <div class="text-2xl font-bold" style="color: var(--color-primary)"><%= @balance %></div>
    <div class="text-xs" style="color: var(--color-outline)">days remaining</div>
  </div>

  <%= form_with model: @holiday_request, url: holiday_requests_path, class: "space-y-6",
      data: { controller: "business-days" } do |f| %>
    <% if @holiday_request.errors.any? %>
      <div class="m3-alert m3-alert-error">
        <ul class="list-disc pl-4 text-sm">
          <% @holiday_request.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <div class="m3-card-elevated p-6 space-y-4">
      <div class="grid grid-cols-2 gap-4">
        <div class="space-y-1">
          <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Start Date</label>
          <%= f.date_field :start_date, class: "m3-text-field w-full", required: true,
              min: Date.current.to_s,
              data: { action: "change->business-days#compute", business_days_target: "startDate" } %>
        </div>
        <div class="space-y-1">
          <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">End Date</label>
          <%= f.date_field :end_date, class: "m3-text-field w-full", required: true,
              min: Date.current.to_s,
              data: { action: "change->business-days#compute", business_days_target: "endDate" } %>
        </div>
      </div>

      <div class="text-sm" style="color: var(--color-on-surface-variant)">
        Business days: <strong data-business-days-target="count">-</strong>
      </div>

      <div class="space-y-1">
        <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Note (optional)</label>
        <%= f.text_area :note, class: "m3-text-field w-full", rows: 3, placeholder: "Reason for time off..." %>
      </div>
    </div>

    <div class="flex gap-2">
      <%= f.submit "Submit Request", class: "m3-btn m3-btn-filled" %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 4: Create the Stimulus controller for business days**

Create `app/javascript/controllers/business_days_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startDate", "endDate", "count"]

  compute() {
    const start = this.startDateTarget.value
    const end = this.endDateTarget.value

    if (!start || !end) {
      this.countTarget.textContent = "-"
      return
    }

    const startDate = new Date(start)
    const endDate = new Date(end)

    if (endDate < startDate) {
      this.countTarget.textContent = "0"
      return
    }

    let count = 0
    const current = new Date(startDate)
    while (current <= endDate) {
      const day = current.getDay()
      if (day !== 0 && day !== 6) count++
      current.setDate(current.getDate() + 1)
    }

    this.countTarget.textContent = count
  }
}
```

- [ ] **Step 5: Register the Stimulus controller**

Check if using importmap auto-loading (esbuild/importmap auto-discovers controllers in `app/javascript/controllers/`). If using importmap with stimulus-loading, the controller should be auto-registered. Verify:

Run: `grep -r "stimulus-loading" app/javascript/`
Expected: Should show the eager-loading line that auto-discovers controllers.

- [ ] **Step 6: Run the controller tests to make sure views render**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb`
Expected: All tests pass (the helper might need to be included — check for errors).

- [ ] **Step 7: Commit**

```bash
git add app/views/holiday_requests/ app/helpers/holiday_requests_helper.rb app/javascript/controllers/business_days_controller.js
git commit -m "feat: add holiday request views with status badges and business days calculator"
```

---

### Task 11: Holiday Balance Entries Views

**Files:**
- Create: `app/views/holiday_balance_entries/index.html.erb`
- Create: `app/views/holiday_balance_entries/new.html.erb`

- [ ] **Step 1: Create the ledger index view**

Create `app/views/holiday_balance_entries/index.html.erb`:

```erb
<div class="space-y-6">
  <div class="flex justify-between items-center">
    <div>
      <h1 class="text-2xl font-bold tracking-tight" style="color: var(--color-on-surface)">
        <% if current_user.admin_or_owner?(current_workspace) && params[:view] == "team" %>
          Team Holiday Balances
        <% elsif @target_user != current_user %>
          Balance History — <%= @target_user.name %>
        <% else %>
          My Balance History
        <% end %>
      </h1>
    </div>
    <div class="flex items-center gap-3">
      <% if @target_user %>
        <div class="text-right">
          <div class="text-2xl font-bold" style="color: var(--color-primary)"><%= @balance %></div>
          <div class="text-xs" style="color: var(--color-outline)">days remaining</div>
        </div>
        <% if current_user.admin_or_owner?(current_workspace) && @target_user != current_user %>
          <%= link_to "Adjust Balance", new_holiday_balance_entry_path(user_id: @target_user.id), class: "m3-btn m3-btn-filled" %>
        <% end %>
      <% end %>
      <%= link_to "Back to Holidays", holiday_requests_path, class: "m3-btn m3-btn-text" %>
    </div>
  </div>

  <%# Year filter %>
  <% unless params[:view] == "team" %>
    <div class="flex gap-2">
      <%= link_to "All", holiday_balance_entries_path(user_id: @target_user&.id),
          class: "m3-btn #{params[:year].blank? ? 'm3-btn-filled' : 'm3-btn-outlined'} m3-btn-sm" %>
      <% (Date.current.year.downto(Date.current.year - 2)).each do |year| %>
        <%= link_to year, holiday_balance_entries_path(user_id: @target_user&.id, year: year),
            class: "m3-btn #{params[:year].to_i == year ? 'm3-btn-filled' : 'm3-btn-outlined'} m3-btn-sm" %>
      <% end %>
    </div>
  <% end %>

  <%# Team overview for admins %>
  <% if current_user.admin_or_owner?(current_workspace) && params[:view] == "team" %>
    <div class="m3-card-outlined overflow-hidden">
      <% current_workspace.workspace_memberships.where.not(role: :client).includes(:user).order("users.name").each do |membership| %>
        <div class="flex items-center justify-between p-4 border-b" style="border-color: var(--color-outline-variant)">
          <div class="flex items-center gap-3">
            <div class="m3-avatar m3-avatar-sm"><%= membership.user.name.first(2).upcase %></div>
            <div>
              <span class="text-sm font-medium" style="color: var(--color-on-surface)"><%= membership.user.name %></span>
              <div class="text-xs" style="color: var(--color-outline)"><%= membership.role %></div>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <div class="text-right">
              <span class="text-lg font-bold" style="color: var(--color-primary)"><%= membership.user.holiday_balance(current_workspace) %></span>
              <span class="text-xs" style="color: var(--color-outline)">days</span>
            </div>
            <div class="flex gap-1">
              <%= link_to "History", holiday_balance_entries_path(user_id: membership.user.id), class: "m3-btn m3-btn-text m3-btn-sm" %>
              <%= link_to "Adjust", new_holiday_balance_entry_path(user_id: membership.user.id), class: "m3-btn m3-btn-outlined m3-btn-sm" %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
  <% else %>
    <%# Ledger entries %>
    <% if @entries.any? %>
      <div class="m3-card-outlined overflow-hidden">
        <table class="w-full text-sm">
          <thead>
            <tr style="background: var(--color-surface-container)">
              <th class="text-left p-3 font-medium" style="color: var(--color-on-surface-variant)">Date</th>
              <th class="text-left p-3 font-medium" style="color: var(--color-on-surface-variant)">Type</th>
              <th class="text-right p-3 font-medium" style="color: var(--color-on-surface-variant)">Days</th>
              <th class="text-left p-3 font-medium" style="color: var(--color-on-surface-variant)">Note</th>
              <th class="text-left p-3 font-medium" style="color: var(--color-on-surface-variant)">By</th>
            </tr>
          </thead>
          <tbody>
            <% @entries.each do |entry| %>
              <tr class="border-t" style="border-color: var(--color-outline-variant)">
                <td class="p-3" style="color: var(--color-on-surface)"><%= entry.created_at.strftime("%b %-d, %Y") %></td>
                <td class="p-3">
                  <span class="text-xs font-medium uppercase tracking-wider" style="color: var(--color-on-surface-variant)">
                    <%= entry.entry_type.humanize %>
                  </span>
                </td>
                <td class="p-3 text-right font-medium" style="color: <%= entry.days > 0 ? '#4CAF50' : 'var(--color-error)' %>">
                  <%= entry.days > 0 ? "+#{entry.days}" : entry.days %>
                </td>
                <td class="p-3" style="color: var(--color-on-surface-variant)"><%= entry.note %></td>
                <td class="p-3" style="color: var(--color-outline)"><%= entry.created_by&.name || "System" %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% else %>
      <div class="m3-card-outlined p-6 text-center">
        <p class="text-sm" style="color: var(--color-outline)">No balance history yet.</p>
      </div>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 2: Create the admin adjustment form**

Create `app/views/holiday_balance_entries/new.html.erb`:

```erb
<div class="max-w-lg mx-auto space-y-6">
  <div class="flex items-center justify-between">
    <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)">Adjust Balance — <%= @target_user.name %></h1>
    <%= link_to "Back", holiday_balance_entries_path(user_id: @target_user.id), class: "m3-btn m3-btn-text" %>
  </div>

  <div class="text-right">
    <div class="text-2xl font-bold" style="color: var(--color-primary)"><%= @balance %></div>
    <div class="text-xs" style="color: var(--color-outline)">current balance</div>
  </div>

  <%= form_with model: @entry, url: holiday_balance_entries_path, class: "space-y-6" do |f| %>
    <% if @entry.errors.any? %>
      <div class="m3-alert m3-alert-error">
        <ul class="list-disc pl-4 text-sm">
          <% @entry.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    <% end %>

    <%= f.hidden_field :user_id, value: @target_user.id %>

    <div class="m3-card-elevated p-6 space-y-4">
      <div class="space-y-1">
        <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Days</label>
        <%= f.number_field :days, class: "m3-text-field w-full", required: true, placeholder: "e.g. 5 or -3" %>
        <p class="text-xs" style="color: var(--color-outline)">Positive to add days, negative to remove.</p>
      </div>

      <div class="space-y-1">
        <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Note (required)</label>
        <%= f.text_area :note, class: "m3-text-field w-full", rows: 3, required: true, placeholder: "Reason for adjustment..." %>
      </div>
    </div>

    <div class="flex gap-2">
      <%= f.submit "Adjust Balance", class: "m3-btn m3-btn-filled" %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 3: Run all controller tests**

Run: `bin/rails test test/controllers/holiday_requests_controller_test.rb test/controllers/holiday_balance_entries_controller_test.rb`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add app/views/holiday_balance_entries/
git commit -m "feat: add holiday balance entries views (ledger + admin adjustment form)"
```

---

### Task 12: Navigation Link + Final Integration

**Files:**
- Modify: `app/views/layouts/application.html.erb:89` — add nav link
- Modify: `app/helpers/workspace_members_helper.rb` or create if needed

- [ ] **Step 1: Add sidebar navigation link**

In `app/views/layouts/application.html.erb`, add after line 89 (`<% end %>` closing the admin_or_owner block) and before line 91 (`<% unless current_user.client_role?(current_workspace) %>` for Tags). Insert a new Holidays link visible to all non-client users:

```erb
            <% unless current_user.client_role?(current_workspace) %>
              <%= link_to holiday_requests_path, class: "m3-nav-item #{request.path.start_with?('/holiday') ? 'active' : ''}" do %>
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 012.25-2.25h13.5A2.25 2.25 0 0121 7.5v11.25m-18 0A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75m-18 0v-7.5A2.25 2.25 0 015.25 9h13.5A2.25 2.25 0 0121 11.25v7.5m-9-6h.008v.008H12v-.008zM12 15h.008v.008H12V15zm0 2.25h.008v.008H12v-.008zM9.75 15h.008v.008H9.75V15zm0 2.25h.008v.008H9.75v-.008zM7.5 15h.008v.008H7.5V15zm0 2.25h.008v.008H7.5v-.008zm6.75-4.5h.008v.008h-.008v-.008zm0 2.25h.008v.008h-.008V15zm0 2.25h.008v.008h-.008v-.008zm2.25-4.5h.008v.008H16.5v-.008zm0 2.25h.008v.008H16.5V15z" /></svg>
                <span>Holidays</span>
              <% end %>
            <% end %>
```

Place this between the closing `<% end %>` of the admin block and the existing `<% unless current_user.client_role?` block that wraps the Tags link.

- [ ] **Step 2: Run the full test suite**

Run: `bin/rails test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "feat: add Holidays nav link in sidebar for all employees"
```

---

### Task 13: Full Integration Test

Run the complete test suite to verify everything works together.

- [ ] **Step 1: Run all tests**

Run: `bin/rails test`
Expected: All tests pass — models, controllers, mailers, and jobs.

- [ ] **Step 2: Start the server and manually verify**

Run: `bin/rails server`

Manual checks:
1. Log in as admin (one@example.com / password)
2. Click "Holidays" in sidebar
3. See balance (should be 0 initially)
4. Go to balance management, adjust balance for a user
5. Create a time off request
6. Approve/cancel from admin view
7. Check email in logs (dev mode)
8. Check balance history shows all entries

- [ ] **Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: final adjustments from integration testing"
```
