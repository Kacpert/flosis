# Discord Time-Logging Reminders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each weekday morning, remind watched users in a Discord group DM if they logged under their threshold on any of the last 3 working days, one staggered message per user.

**Architecture:** A `DiscordGroupClient` (Net::HTTP) posts to the group DM using a throwaway user token from Rails credentials. A `DiscordReminderRecipient` table (managed in a Workspace Settings section) lists watched users. A recurring `DiscordReminderJob` computes who's under threshold (skipping approved-holiday days) and enqueues one `DiscordReminderMessageJob` per offender, spaced 2 minutes apart.

**Tech Stack:** Rails 8.1.2, Minitest, WebMock (test HTTP stubbing), Solid Queue (recurring jobs + scheduled `wait`), Net::HTTP.

---

## File Structure

- `app/services/discord_group_client.rb` — Net::HTTP wrapper; `post(content)`, `configured?`.
- `db/migrate/20260610000001_create_discord_reminder_recipients.rb` + `app/models/discord_reminder_recipient.rb` — watched users.
- `app/jobs/discord_reminder_job.rb` — daily check, enqueues message jobs.
- `app/jobs/discord_reminder_message_job.rb` — posts one recipient's message.
- `app/controllers/discord_reminder_recipients_controller.rb` — admin CRUD.
- `config/routes.rb` — `resources :discord_reminder_recipients, only: [:create, :update, :destroy]`.
- `app/views/workspace_settings/show.html.erb` — add "Discord reminders" section.
- `app/controllers/workspace_settings_controller.rb` — load `@discord_recipients` + `@workspace_users` for the section.
- `config/recurring.yml` — schedule the daily job.
- Tests: `test/services/discord_group_client_test.rb`, `test/models/discord_reminder_recipient_test.rb`, `test/jobs/discord_reminder_job_test.rb`, `test/jobs/discord_reminder_message_job_test.rb`, `test/controllers/discord_reminder_recipients_controller_test.rb`.

### Verified facts
- App uses `Net::HTTP` (see `JiraClient`); rescue list `Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED`. `webmock` gem available for stubbing.
- `TimeEntry`: `scope :completed`, `scope :for_date(date)` (started_at within that day), `duration_seconds`.
- `HolidayRequest`: `enum status { pending:0, approved:1, cancelled:2 }`.
- Credentials via `Rails.application.credentials.dig(:discord, :user_token)` / `:group_channel_id`.
- Discord: `https://discord.com/api/v10`, raw user token in `Authorization` (no `Bot `), send `User-Agent`. Verified working with channel `1159158381194522684`.
- `WorkspaceSettingsController#require_admin!`; view uses `m3-card-elevated`, `m3-btn m3-btn-filled`, `m3-text-field`, `m3-checkbox`.
- `users(:one)` = owner/admin of `workspaces(:one)`; `users(:two)` = employee. `workspaces(:one)`.
- Test queue adapter is `:test` → `assert_enqueued_with` available.

---

### Task 1: `DiscordGroupClient` service

**Files:**
- Create: `app/services/discord_group_client.rb`
- Test: `test/services/discord_group_client_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/discord_group_client_test.rb`:

```ruby
require "test_helper"

class DiscordGroupClientTest < ActiveSupport::TestCase
  def client
    DiscordGroupClient.new(token: "tok-123", channel_id: "999")
  end

  test "configured? is false when token or channel missing" do
    assert_not DiscordGroupClient.new(token: nil, channel_id: "999").configured?
    assert_not DiscordGroupClient.new(token: "x", channel_id: nil).configured?
    assert client.configured?
  end

  test "post sends the message and returns true on 200" do
    stub = stub_request(:post, "https://discord.com/api/v10/channels/999/messages")
      .with(
        headers: { "Authorization" => "tok-123", "Content-Type" => "application/json" },
        body: { content: "hello" }.to_json
      )
      .to_return(status: 200, body: { id: "1" }.to_json)

    assert client.post("hello")
    assert_requested stub
  end

  test "post returns false on a non-2xx response without raising" do
    stub_request(:post, "https://discord.com/api/v10/channels/999/messages")
      .to_return(status: 500, body: "nope")
    assert_not client.post("hello")
  end

  test "post returns false on a network error without raising" do
    stub_request(:post, "https://discord.com/api/v10/channels/999/messages")
      .to_raise(SocketError.new("boom"))
    assert_not client.post("hello")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/discord_group_client_test.rb`
Expected: FAIL — `uninitialized constant DiscordGroupClient`.

- [ ] **Step 3: Implement the service**

Create `app/services/discord_group_client.rb`:

```ruby
require "net/http"
require "json"

# Posts messages to a Discord group DM using a user-account token (group DMs
# cannot use webhooks or bot tokens). Token + channel id come from Rails
# encrypted credentials (discord.user_token / discord.group_channel_id).
class DiscordGroupClient
  API_BASE = "https://discord.com/api/v10".freeze
  TIMEOUT  = 10

  def initialize(token: nil, channel_id: nil)
    creds = Rails.application.credentials.discord || {}
    @token = token || creds[:user_token]
    @channel_id = channel_id || creds[:group_channel_id]
  end

  def configured?
    @token.present? && @channel_id.present?
  end

  # Returns true on success, false (logged) on any failure. Never raises.
  def post(content)
    return false unless configured?

    uri = URI("#{API_BASE}/channels/#{@channel_id}/messages")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = @token # raw user token, no "Bot " prefix
    request["Content-Type"] = "application/json"
    request["User-Agent"] = "Clar (https://clar.rubyonsaas.com, 1.0)"
    request.body = { content: content }.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(request)
    return true if response.is_a?(Net::HTTPSuccess)

    Rails.logger.error("[DiscordGroupClient] post failed: #{response.code} #{response.message}")
    false
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.error("[DiscordGroupClient] post error: #{e.message}")
    false
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/discord_group_client_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/discord_group_client.rb test/services/discord_group_client_test.rb
git commit -m "feat: DiscordGroupClient posts to a group DM via Net::HTTP"
```

---

### Task 2: `DiscordReminderRecipient` model + migration

**Files:**
- Create: `db/migrate/20260610000001_create_discord_reminder_recipients.rb`
- Create: `app/models/discord_reminder_recipient.rb`
- Test: `test/models/discord_reminder_recipient_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/discord_reminder_recipient_test.rb`:

```ruby
require "test_helper"

class DiscordReminderRecipientTest < ActiveSupport::TestCase
  def build_recipient(attrs = {})
    DiscordReminderRecipient.new({
      workspace: workspaces(:one),
      user: users(:two),
      discord_user_id: "123456789",
      min_daily_hours: 4.0
    }.merge(attrs))
  end

  test "valid with required attributes" do
    assert build_recipient.valid?
  end

  test "discord_user_id must be present and numeric" do
    assert_not build_recipient(discord_user_id: "").valid?
    assert_not build_recipient(discord_user_id: "abc").valid?
    assert build_recipient(discord_user_id: "42").valid?
  end

  test "min_daily_hours must be positive" do
    assert_not build_recipient(min_daily_hours: 0).valid?
    assert_not build_recipient(min_daily_hours: -1).valid?
  end

  test "user is unique per workspace" do
    build_recipient.save!
    dup = build_recipient(discord_user_id: "999")
    assert_not dup.valid?
  end

  test "defaults: active true, min_daily_hours 4.0" do
    r = DiscordReminderRecipient.new(workspace: workspaces(:one), user: users(:two), discord_user_id: "1")
    assert r.active
    assert_equal 4.0, r.min_daily_hours.to_f
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/discord_reminder_recipient_test.rb`
Expected: FAIL — `uninitialized constant DiscordReminderRecipient`.

- [ ] **Step 3: Create the migration**

Create `db/migrate/20260610000001_create_discord_reminder_recipients.rb`:

```ruby
class CreateDiscordReminderRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_reminder_recipients do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :discord_user_id, null: false
      t.decimal :min_daily_hours, precision: 4, scale: 1, null: false, default: 4.0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :discord_reminder_recipients, [:workspace_id, :user_id], unique: true
  end
end
```

- [ ] **Step 4: Migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: table created; `db/schema.rb` shows `discord_reminder_recipients`.

- [ ] **Step 5: Create the model**

Create `app/models/discord_reminder_recipient.rb`:

```ruby
class DiscordReminderRecipient < ApplicationRecord
  belongs_to :workspace
  belongs_to :user

  validates :discord_user_id, presence: true, format: { with: /\A\d+\z/, message: "must be a numeric Discord ID" }
  validates :min_daily_hours, numericality: { greater_than: 0 }
  validates :user_id, uniqueness: { scope: :workspace_id }

  scope :active, -> { where(active: true) }
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/models/discord_reminder_recipient_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260610000001_create_discord_reminder_recipients.rb db/schema.rb app/models/discord_reminder_recipient.rb test/models/discord_reminder_recipient_test.rb
git commit -m "feat: DiscordReminderRecipient model for watched users"
```

---

### Task 3: `DiscordReminderMessageJob`

**Files:**
- Create: `app/jobs/discord_reminder_message_job.rb`
- Test: `test/jobs/discord_reminder_message_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/discord_reminder_message_job_test.rb`:

```ruby
require "test_helper"

class DiscordReminderMessageJobTest < ActiveJob::TestCase
  test "posts a mention message for the recipient" do
    recipient = DiscordReminderRecipient.create!(
      workspace: workspaces(:one), user: users(:two),
      discord_user_id: "555", min_daily_hours: 4.0
    )

    captured = nil
    fake = Object.new
    fake.define_singleton_method(:post) { |content| captured = content; true }

    DiscordGroupClient.stub(:new, fake) do
      DiscordReminderMessageJob.perform_now(recipient.id)
    end

    assert_includes captured, "<@555>"
    assert_includes captured, "4.0h"
  end

  test "no-ops when the recipient is missing" do
    fake = Object.new
    fake.define_singleton_method(:post) { |_| raise "should not be called" }
    DiscordGroupClient.stub(:new, fake) do
      assert_nothing_raised { DiscordReminderMessageJob.perform_now(-1) }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/discord_reminder_message_job_test.rb`
Expected: FAIL — `uninitialized constant DiscordReminderMessageJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/discord_reminder_message_job.rb`:

```ruby
class DiscordReminderMessageJob < ApplicationJob
  queue_as :default

  def perform(recipient_id)
    recipient = DiscordReminderRecipient.find_by(id: recipient_id, active: true)
    return unless recipient

    hours = format("%g", recipient.min_daily_hours)
    content = "<@#{recipient.discord_user_id}> you logged under #{hours}h on one " \
              "or more of the last 3 working days — please log your time 🙏"

    DiscordGroupClient.new.post(content)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/discord_reminder_message_job_test.rb`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/discord_reminder_message_job.rb test/jobs/discord_reminder_message_job_test.rb
git commit -m "feat: DiscordReminderMessageJob posts one recipient reminder"
```

---

### Task 4: `DiscordReminderJob` (daily check)

**Files:**
- Create: `app/jobs/discord_reminder_job.rb`
- Test: `test/jobs/discord_reminder_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/discord_reminder_job_test.rb`:

```ruby
require "test_helper"

class DiscordReminderJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    # Make the client appear configured so the job proceeds.
    @configured_client = Object.new
    @configured_client.define_singleton_method(:configured?) { true }
  end

  # Helper: a recent weekday (avoid weekends in assertions by using a fixed Monday).
  def working_day
    # 2026-06-08 is a Monday.
    Date.new(2026, 6, 8)
  end

  def add_entry(user, date, hours)
    @workspace.time_entries.create!(
      user: user, project: projects(:jira_project),
      started_at: date.to_time + 9.hours,
      stopped_at: date.to_time + 9.hours + hours.hours
    )
  end

  def recipient_for(user, threshold: 4.0)
    DiscordReminderRecipient.create!(
      workspace: @workspace, user: user,
      discord_user_id: "100#{user.id}", min_daily_hours: threshold
    )
  end

  test "enqueues a message job for a user under threshold on a working day" do
    travel_to working_day + 1.day do # 'today' is Tue; window = Mon + prior 2 working days
      r = recipient_for(users(:two), threshold: 4.0)
      add_entry(users(:two), working_day, 1) # only 1h on Monday -> under 4h

      DiscordGroupClient.stub(:new, @configured_client) do
        assert_enqueued_with(job: DiscordReminderMessageJob, args: [r.id]) do
          DiscordReminderJob.perform_now
        end
      end
    end
  end

  test "does not enqueue when the user met the threshold every eligible day" do
    travel_to working_day + 1.day do
      recipient_for(users(:two), threshold: 4.0)
      # Fill all three working days in the window with 8h each.
      [working_day, working_day - 1.day, working_day - 4.days].each do |d|
        add_entry(users(:two), d, 8)
      end

      DiscordGroupClient.stub(:new, @configured_client) do
        assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
          DiscordReminderJob.perform_now
        end
      end
    end
  end

  test "skips approved-holiday days when evaluating" do
    travel_to working_day + 1.day do
      recipient_for(users(:two), threshold: 4.0)
      # User logged nothing on Monday, but was on approved holiday that day.
      HolidayRequest.create!(
        workspace: @workspace, user: users(:two),
        start_date: working_day, end_date: working_day, status: :approved,
        business_days: 1, reviewed_by: users(:one)
      )
      # Other two working days are fully logged.
      [working_day - 1.day, working_day - 4.days].each { |d| add_entry(users(:two), d, 8) }

      DiscordGroupClient.stub(:new, @configured_client) do
        assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
          DiscordReminderJob.perform_now
        end
      end
    end
  end

  test "no-ops when the client is not configured" do
    travel_to working_day + 1.day do
      recipient_for(users(:two))
      add_entry(users(:two), working_day, 0.5)
      unconfigured = Object.new
      unconfigured.define_singleton_method(:configured?) { false }

      DiscordGroupClient.stub(:new, unconfigured) do
        assert_no_enqueued_jobs(only: DiscordReminderMessageJob) do
          DiscordReminderJob.perform_now
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/discord_reminder_job_test.rb`
Expected: FAIL — `uninitialized constant DiscordReminderJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/discord_reminder_job.rb`:

```ruby
class DiscordReminderJob < ApplicationJob
  queue_as :default

  WORKING_DAYS_WINDOW = 3
  STAGGER = 2.minutes

  def perform
    return unless DiscordGroupClient.new.configured?

    window = last_working_days(WORKING_DAYS_WINDOW)
    return if window.empty?

    index = 0
    DiscordReminderRecipient.active.includes(:user, :workspace).find_each do |recipient|
      next unless under_threshold?(recipient, window)
      DiscordReminderMessageJob.set(wait: index * STAGGER).perform_later(recipient.id)
      index += 1
    end
  end

  private

  # The last N working days (Mon–Fri) ending yesterday (today is still in progress).
  def last_working_days(count)
    days = []
    day = Date.yesterday
    while days.size < count
      days << day unless day.saturday? || day.sunday?
      day -= 1.day
    end
    days
  end

  def under_threshold?(recipient, window)
    eligible = window.reject { |d| on_approved_holiday?(recipient, d) }
    return false if eligible.empty?

    min_seconds = (recipient.min_daily_hours * 3600).to_i
    eligible.any? do |day|
      seconds = recipient.workspace.time_entries.completed
        .where(user_id: recipient.user_id)
        .for_date(day)
        .sum(:duration_seconds)
      seconds < min_seconds
    end
  end

  def on_approved_holiday?(recipient, day)
    HolidayRequest
      .where(workspace_id: recipient.workspace_id, user_id: recipient.user_id, status: :approved)
      .where("start_date <= ? AND end_date >= ?", day, day)
      .exists?
  end
end
```

The `index` declared before the loop persists across iterations, so each
enqueued message job is staggered by `index * 2.minutes`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/discord_reminder_job_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/discord_reminder_job.rb test/jobs/discord_reminder_job_test.rb
git commit -m "feat: DiscordReminderJob flags under-logged users and enqueues reminders"
```

---

### Task 5: Admin CRUD controller + route

**Files:**
- Modify: `config/routes.rb` (add after `resource :workspace_settings`)
- Create: `app/controllers/discord_reminder_recipients_controller.rb`
- Test: `test/controllers/discord_reminder_recipients_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/controllers/discord_reminder_recipients_controller_test.rb`:

```ruby
require "test_helper"

class DiscordReminderRecipientsControllerTest < ActionDispatch::IntegrationTest
  test "admin can create a recipient" do
    sign_in_as(users(:one))
    assert_difference "DiscordReminderRecipient.count", 1 do
      post discord_reminder_recipients_path, params: {
        discord_reminder_recipient: { user_id: users(:two).id, discord_user_id: "777", min_daily_hours: 6 }
      }
    end
    assert_redirected_to workspace_settings_path
  end

  test "admin can update a recipient" do
    sign_in_as(users(:one))
    r = DiscordReminderRecipient.create!(workspace: workspaces(:one), user: users(:two), discord_user_id: "1", min_daily_hours: 4)
    patch discord_reminder_recipient_path(r), params: { discord_reminder_recipient: { min_daily_hours: 8, active: false } }
    assert_redirected_to workspace_settings_path
    r.reload
    assert_equal 8.0, r.min_daily_hours.to_f
    assert_not r.active
  end

  test "admin can destroy a recipient" do
    sign_in_as(users(:one))
    r = DiscordReminderRecipient.create!(workspace: workspaces(:one), user: users(:two), discord_user_id: "1", min_daily_hours: 4)
    assert_difference "DiscordReminderRecipient.count", -1 do
      delete discord_reminder_recipient_path(r)
    end
    assert_redirected_to workspace_settings_path
  end

  test "employee is blocked" do
    sign_in_as(users(:two))
    assert_no_difference "DiscordReminderRecipient.count" do
      post discord_reminder_recipients_path, params: {
        discord_reminder_recipient: { user_id: users(:one).id, discord_user_id: "1", min_daily_hours: 4 }
      }
    end
    assert_redirected_to root_path
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/discord_reminder_recipients_controller_test.rb`
Expected: FAIL — no route / controller.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, immediately after the `resource :workspace_settings, only: [ :show, :update ]` line, add:

```ruby
  resources :discord_reminder_recipients, only: [ :create, :update, :destroy ]
```

- [ ] **Step 4: Create the controller**

Create `app/controllers/discord_reminder_recipients_controller.rb`:

```ruby
class DiscordReminderRecipientsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :set_recipient, only: %i[update destroy]

  def create
    recipient = current_workspace.discord_reminder_recipients.build(recipient_params)
    if recipient.save
      redirect_to workspace_settings_path, notice: "Discord recipient added."
    else
      redirect_to workspace_settings_path, alert: recipient.errors.full_messages.to_sentence
    end
  end

  def update
    if @recipient.update(recipient_params)
      redirect_to workspace_settings_path, notice: "Discord recipient updated."
    else
      redirect_to workspace_settings_path, alert: @recipient.errors.full_messages.to_sentence
    end
  end

  def destroy
    @recipient.destroy
    redirect_to workspace_settings_path, notice: "Discord recipient removed.", status: :see_other
  end

  private

  def set_recipient
    @recipient = current_workspace.discord_reminder_recipients.find(params[:id])
  end

  def recipient_params
    params.require(:discord_reminder_recipient).permit(:user_id, :discord_user_id, :min_daily_hours, :active)
  end
end
```

- [ ] **Step 5: Add the association to Workspace**

In `app/models/workspace.rb`, add alongside the other `has_many` lines:

```ruby
  has_many :discord_reminder_recipients, dependent: :destroy
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/controllers/discord_reminder_recipients_controller_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/discord_reminder_recipients_controller.rb app/models/workspace.rb test/controllers/discord_reminder_recipients_controller_test.rb
git commit -m "feat: admin CRUD for Discord reminder recipients"
```

---

### Task 6: Workspace Settings UI section

**Files:**
- Modify: `app/controllers/workspace_settings_controller.rb` (`show`)
- Modify: `app/views/workspace_settings/show.html.erb`

- [ ] **Step 1: Load data in the controller**

In `app/controllers/workspace_settings_controller.rb`, change `show` to:

```ruby
  def show
    @workspace = current_workspace
    @discord_recipients = current_workspace.discord_reminder_recipients.includes(:user).order("users.name")
    @workspace_users = current_workspace.users.order(:name)
  end
```

- [ ] **Step 2: Add the section to the view**

In `app/views/workspace_settings/show.html.erb`, before the final closing
`</div>` (after the Features form block), add:

```erb
  <div class="m3-card-elevated p-6 space-y-4">
    <div>
      <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">Discord reminders</h2>
      <p class="text-sm" style="color: var(--color-on-surface-variant)">
        Watched users are pinged in the team Discord group if they log under their
        daily hours threshold on any of the last 3 working days.
      </p>
    </div>

    <% if @discord_recipients.any? %>
      <div class="m3-card-outlined overflow-hidden">
        <% @discord_recipients.each do |recipient| %>
          <%= form_with model: recipient, url: discord_reminder_recipient_path(recipient), method: :patch,
                class: "flex items-center gap-3 p-3 border-b" do |f| %>
            <div class="flex-1">
              <div class="text-sm font-medium" style="color: var(--color-on-surface)"><%= recipient.user.name %></div>
              <div class="text-xs" style="color: var(--color-outline)">Discord ID: <%= recipient.discord_user_id %></div>
            </div>
            <%= f.number_field :min_daily_hours, step: 0.5, min: 0.5, class: "m3-text-field w-20 text-right text-sm" %>
            <span class="text-xs" style="color: var(--color-outline)">h/day</span>
            <label class="flex items-center gap-1 text-xs" style="color: var(--color-on-surface-variant)">
              <%= f.check_box :active, class: "m3-checkbox" %> active
            </label>
            <%= f.submit "Save", class: "m3-btn m3-btn-text m3-btn-sm" %>
            <%= button_to "Remove", discord_reminder_recipient_path(recipient), method: :delete,
                  class: "text-xs font-medium", style: "color: var(--color-error)",
                  form: { data: { turbo_confirm: "Remove #{recipient.user.name}?" } } %>
          <% end %>
        <% end %>
      </div>
    <% end %>

    <%= form_with url: discord_reminder_recipients_path, method: :post, class: "flex items-end gap-3" do |f| %>
      <div class="flex-1">
        <label class="block text-xs mb-1" style="color: var(--color-on-surface-variant)">User</label>
        <%= f.select :"discord_reminder_recipient[user_id]",
              @workspace_users.map { |u| [u.name, u.id] }, {}, class: "m3-text-field w-full" %>
      </div>
      <div>
        <label class="block text-xs mb-1" style="color: var(--color-on-surface-variant)">Discord ID</label>
        <%= f.text_field :"discord_reminder_recipient[discord_user_id]", class: "m3-text-field w-40" %>
      </div>
      <div>
        <label class="block text-xs mb-1" style="color: var(--color-on-surface-variant)">h/day</label>
        <%= f.number_field :"discord_reminder_recipient[min_daily_hours]", value: 4.0, step: 0.5, min: 0.5, class: "m3-text-field w-20" %>
      </div>
      <%= f.submit "Add", class: "m3-btn m3-btn-filled m3-btn-sm" %>
    <% end %>
  </div>
</div>
```

Replace the file's final `</div>` with the block above (which ends with that
`</div>`), so the new card sits inside the page's outer wrapper.

- [ ] **Step 3: Build CSS and smoke-test the page renders**

Run: `bin/rails tailwindcss:build`
Then: `bin/rails test test/controllers/discord_reminder_recipients_controller_test.rb` (still green) and manually confirm `WorkspaceSettingsController#show` renders by re-running `test/controllers/workspace_settings_controller_test.rb`.

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS (existing tests still green with the new `show` assigns).

- [ ] **Step 4: Commit**

```bash
git add app/controllers/workspace_settings_controller.rb app/views/workspace_settings/show.html.erb
git commit -m "feat: Discord reminders management section on workspace settings"
```

---

### Task 7: Schedule + regression + deploy

**Files:**
- Modify: `config/recurring.yml`

- [ ] **Step 1: Add the recurring schedule**

In `config/recurring.yml`, under `production:`, add:

```yaml
  discord_time_logging_reminders:
    class: DiscordReminderJob
    schedule: "0 9 * * 1-5"
```

- [ ] **Step 2: Run the full new-feature test set**

Run: `bin/rails test test/services/discord_group_client_test.rb test/models/discord_reminder_recipient_test.rb test/jobs/discord_reminder_message_job_test.rb test/jobs/discord_reminder_job_test.rb test/controllers/discord_reminder_recipients_controller_test.rb test/controllers/workspace_settings_controller_test.rb`
Expected: all PASS, 0 failures.

- [ ] **Step 3: Full suite regression**

Run: `bin/rails test test/controllers test/models test/jobs test/services`
Expected: no NEW failures beyond the known pre-existing holiday-overlap failure.

- [ ] **Step 4: Set production credentials**

Before deploying, add to Rails encrypted credentials (`bin/rails credentials:edit`) a FRESH `clarhelper` token (the testing token is burned):

```yaml
discord:
  user_token: "<fresh clarhelper token>"
  group_channel_id: "1159158381194522684"
```

Ensure `config/master.key` is present on the server (Capistrano linked file) so production can decrypt.

- [ ] **Step 5: Push and deploy**

```bash
git push origin production
cap production deploy
```

Expected: deploy exits 0; migration runs; full puma restart; Solid Queue picks up the new recurring entry.

- [ ] **Step 6: Verify**

- Open Workspace Settings → confirm the "Discord reminders" section; add yourself (or a test user) with your Discord ID and a high threshold (e.g. 24h) so the next run flags you.
- Optionally trigger once on the server: `bin/rails runner "DiscordReminderJob.perform_now"` and confirm a message lands in the group (and that messages are staggered if multiple).

---

## Notes for the implementer

- The testing token from the chat is burned — reset the `clarhelper` account token and use a fresh one in production credentials.
- The job no-ops cleanly if credentials are absent (e.g. in dev), so it's safe to deploy before credentials are set.
- Messages stagger via Solid Queue `set(wait:)` — real delayed jobs, not `sleep`.
- The window is the last 3 working days ending **yesterday**; today is excluded because it is still in progress.
