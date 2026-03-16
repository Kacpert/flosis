# Jira Task Chat Mode Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AI chat mode to the Jira task detail view that spawns a Claude Code subprocess for interactive coding assistance, with three UI states (normal, side-by-side, fullscreen).

**Architecture:** Two new models (ChatSession, ChatMessage) store conversation state. A new ChatSessionsController handles session creation and message streaming via ActionController::Live + SSE. A Stimulus controller (`task-chat`) manages the three UI states by toggling visibility of the layout sidebar, details panel, and task content. The Claude CLI is invoked via `IO.popen` with array form (no shell interpolation), using `--resume` for multi-turn conversations and `--add-dir` for codebase access.

**Tech Stack:** Rails 8.1, Stimulus, ActionController::Live (SSE), Claude Code CLI (`claude -p`), Tailwind CSS with M3 design tokens.

**Spec:** `docs/superpowers/specs/2026-03-16-jira-task-chat-mode-design.md`

---

## File Structure

### New Files
- `db/migrate/TIMESTAMP_create_chat_sessions.rb` — migration for chat_sessions table
- `db/migrate/TIMESTAMP_create_chat_messages.rb` — migration for chat_messages table
- `app/models/chat_session.rb` — ChatSession model
- `app/models/chat_message.rb` — ChatMessage model
- `app/controllers/chat_sessions_controller.rb` — handles create, show, message actions
- `app/services/claude_cli_service.rb` — wraps Claude CLI subprocess spawning
- `app/javascript/controllers/task_chat_controller.js` — Stimulus controller for 3-state UI
- `app/views/jira_tasks/_chat_panel.html.erb` — chat panel partial (messages + input)
- `app/views/jira_tasks/_chat_header.html.erb` — compact header for fullscreen mode
- `test/fixtures/chat_sessions.yml` — test fixtures
- `test/fixtures/chat_messages.yml` — test fixtures
- `test/models/chat_session_test.rb` — model tests
- `test/models/chat_message_test.rb` — model tests
- `test/controllers/chat_sessions_controller_test.rb` — controller tests
- `test/services/claude_cli_service_test.rb` — service tests

### Modified Files
- `config/routes.rb` — add nested chat_session routes under jira_tasks
- `app/models/task.rb` — add `has_many :chat_sessions`
- `app/models/user.rb` — add `has_many :chat_sessions`
- `app/models/workspace.rb` — add `has_many :chat_sessions`
- `app/views/jira_tasks/show.html.erb` — add chat button, chat panel, data-controller
- `app/views/layouts/application.html.erb` — add `id="app-sidebar"` to aside element

---

## Chunk 1: Data Layer (Models + Migrations)

### Task 1: Create ChatSession migration and model

**Files:**
- Create: `db/migrate/TIMESTAMP_create_chat_sessions.rb`
- Create: `app/models/chat_session.rb`
- Create: `test/fixtures/chat_sessions.yml`
- Create: `test/models/chat_session_test.rb`
- Modify: `app/models/task.rb:1-11`

- [ ] **Step 1: Write ChatSession model test**

Create `test/models/chat_session_test.rb`:

```ruby
require "test_helper"

class ChatSessionTest < ActiveSupport::TestCase
  test "belongs to task" do
    session = chat_sessions(:one)
    assert_equal tasks(:jira_task), session.task
  end

  test "belongs to workspace" do
    session = chat_sessions(:one)
    assert_equal workspaces(:one), session.workspace
  end

  test "belongs to user" do
    session = chat_sessions(:one)
    assert_equal users(:one), session.user
  end

  test "has many chat messages" do
    session = chat_sessions(:one)
    assert_respond_to session, :chat_messages
  end

  test "validates presence of claude_session_id" do
    session = ChatSession.new(task: tasks(:jira_task), workspace: workspaces(:one), user: users(:one), status: "active")
    assert_not session.valid?
    assert_includes session.errors[:claude_session_id], "can't be blank"
  end

  test "validates presence of codebase_path" do
    session = ChatSession.new(task: tasks(:jira_task), workspace: workspaces(:one), user: users(:one), claude_session_id: "abc", status: "active")
    assert_not session.valid?
    assert_includes session.errors[:codebase_path], "can't be blank"
  end

  test "active scope returns only active sessions" do
    assert_includes ChatSession.active, chat_sessions(:one)
  end

  test "find_active_for returns active session for task and user" do
    session = ChatSession.find_active_for(tasks(:jira_task), users(:one))
    assert_equal chat_sessions(:one), session
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/chat_session_test.rb`
Expected: Error — `ChatSession` class not found

- [ ] **Step 3: Create the migration**

Run: `bin/rails generate migration CreateChatSessions`

Then edit the generated migration file:

```ruby
class CreateChatSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_sessions do |t|
      t.references :task, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :claude_session_id, null: false
      t.string :codebase_path, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end

    add_index :chat_sessions, [:task_id, :user_id, :status], unique: true, where: "status = 'active'", name: "idx_chat_sessions_active_per_task_user"
  end
end
```

- [ ] **Step 4: Run migration**

Run: `bin/rails db:migrate`
Expected: Migration succeeds, schema updated

- [ ] **Step 5: Create the model**

Create `app/models/chat_session.rb`:

```ruby
class ChatSession < ApplicationRecord
  belongs_to :task
  belongs_to :workspace
  belongs_to :user

  has_many :chat_messages, dependent: :destroy

  validates :claude_session_id, presence: true
  validates :codebase_path, presence: true
  validates :status, presence: true, inclusion: { in: %w[active closed] }

  scope :active, -> { where(status: "active") }

  def self.find_active_for(task, user)
    active.find_by(task: task, user: user)
  end
end
```

- [ ] **Step 6: Create fixture**

Create `test/fixtures/chat_sessions.yml`:

```yaml
one:
  task: jira_task
  workspace: one
  user: one
  claude_session_id: "test-session-uuid-123"
  codebase_path: "/tmp/test-codebase"
  status: active
```

- [ ] **Step 7: Add associations to models**

Modify `app/models/task.rb` — add after `has_many :time_entries, dependent: :nullify`:

```ruby
has_many :chat_sessions, dependent: :destroy
```

Modify `app/models/user.rb` — add alongside other `has_many` associations:

```ruby
has_many :chat_sessions, dependent: :destroy
```

Modify `app/models/workspace.rb` — add alongside other `has_many` associations:

```ruby
has_many :chat_sessions, dependent: :destroy
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `bin/rails test test/models/chat_session_test.rb`
Expected: All tests pass

- [ ] **Step 9: Commit**

```bash
git add db/migrate/*_create_chat_sessions.rb app/models/chat_session.rb test/models/chat_session_test.rb test/fixtures/chat_sessions.yml app/models/task.rb app/models/user.rb app/models/workspace.rb db/schema.rb
git commit -m "feat: add ChatSession model with migration and tests"
```

---

### Task 2: Create ChatMessage migration and model

**Files:**
- Create: `db/migrate/TIMESTAMP_create_chat_messages.rb`
- Create: `app/models/chat_message.rb`
- Create: `test/fixtures/chat_messages.yml`
- Create: `test/models/chat_message_test.rb`

- [ ] **Step 1: Write ChatMessage model test**

Create `test/models/chat_message_test.rb`:

```ruby
require "test_helper"

class ChatMessageTest < ActiveSupport::TestCase
  test "belongs to chat session" do
    message = chat_messages(:greeting)
    assert_equal chat_sessions(:one), message.chat_session
  end

  test "validates presence of role" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), content: "hello")
    assert_not message.valid?
    assert_includes message.errors[:role], "can't be blank"
  end

  test "validates role inclusion" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), content: "hello", role: "invalid")
    assert_not message.valid?
    assert_includes message.errors[:role], "is not included in the list"
  end

  test "validates presence of content" do
    message = ChatMessage.new(chat_session: chat_sessions(:one), role: "user")
    assert_not message.valid?
    assert_includes message.errors[:content], "can't be blank"
  end

  test "ordered scope returns messages in chronological order" do
    assert_equal chat_messages(:greeting), chat_sessions(:one).chat_messages.ordered.first
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/chat_message_test.rb`
Expected: Error — `ChatMessage` class not found

- [ ] **Step 3: Create the migration**

Run: `bin/rails generate migration CreateChatMessages`

Then edit the generated migration:

```ruby
class CreateChatMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_messages do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content, null: false
      t.timestamps
    end
  end
end
```

- [ ] **Step 4: Run migration**

Run: `bin/rails db:migrate`
Expected: Migration succeeds

- [ ] **Step 5: Create the model**

Create `app/models/chat_message.rb`:

```ruby
class ChatMessage < ApplicationRecord
  belongs_to :chat_session

  validates :role, presence: true, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true

  scope :ordered, -> { order(:created_at) }
end
```

- [ ] **Step 6: Create fixture**

Create `test/fixtures/chat_messages.yml`:

```yaml
greeting:
  chat_session: one
  role: assistant
  content: "I've read the ticket. What would you like to work on?"

user_first:
  chat_session: one
  role: user
  content: "Start with the data model"
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bin/rails test test/models/chat_message_test.rb`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add db/migrate/*_create_chat_messages.rb app/models/chat_message.rb test/models/chat_message_test.rb test/fixtures/chat_messages.yml db/schema.rb
git commit -m "feat: add ChatMessage model with migration and tests"
```

---

## Chunk 2: Service Layer (Claude CLI Service)

### Task 3: Create ClaudeCliService

**Files:**
- Create: `app/services/claude_cli_service.rb`
- Create: `test/services/claude_cli_service_test.rb`

- [ ] **Step 1: Write ClaudeCliService tests**

Create `test/services/claude_cli_service_test.rb`:

```ruby
require "test_helper"

class ClaudeCliServiceTest < ActiveSupport::TestCase
  setup do
    @codebase_path = "/tmp/test-codebase"
  end

  test "start_session returns session_id and response" do
    fake_result = {
      "type" => "result",
      "subtype" => "success",
      "result" => "I've read the ticket. How can I help?",
      "session_id" => "fake-uuid-123"
    }.to_json

    service = ClaudeCliService.new(codebase_path: @codebase_path)

    IO.stub(:popen, ->(*_args) { StringIO.new(fake_result) }) do
      result = service.start_session(prompt: "Help with ticket DEV-1")
      assert_equal "fake-uuid-123", result[:session_id]
      assert_equal "I've read the ticket. How can I help?", result[:response]
    end
  end

  test "build_command includes resume flag when session_id provided" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, session_id: "abc-123", streaming: false)

    assert_kind_of Array, cmd
    assert_includes cmd, "--resume"
    assert_includes cmd, "abc-123"
    assert_includes cmd, "--add-dir"
    assert_includes cmd, @codebase_path
  end

  test "build_command uses array form not string" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: true)

    assert_kind_of Array, cmd
    assert_equal "claude", cmd.first
    assert_includes cmd, "--output-format"
    assert_includes cmd, "stream-json"
  end

  test "send_message_streaming yields lines from subprocess" do
    lines = [
      { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "Hello" }] } }.to_json,
      { "type" => "result", "result" => "Hello", "session_id" => "abc" }.to_json
    ].join("\n") + "\n"

    fake_io = StringIO.new(lines)
    fake_io.define_singleton_method(:write) { |_| }
    fake_io.define_singleton_method(:close_write) { }

    service = ClaudeCliService.new(codebase_path: @codebase_path)
    collected = []

    IO.stub(:popen, ->(*_args) { |&blk| blk.call(fake_io) }) do
      service.send_message_streaming(session_id: "abc", message: "Hi") do |line|
        collected << line
      end
    end

    assert_equal 2, collected.length
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/claude_cli_service_test.rb`
Expected: Error — `ClaudeCliService` not found

- [ ] **Step 3: Create the service**

Create `app/services/claude_cli_service.rb`:

```ruby
class ClaudeCliService
  CLAUDE_CMD = "claude".freeze
  DEFAULT_CODEBASE_PATH = File.expand_path("~/work/elvium").freeze

  def initialize(codebase_path: nil)
    @codebase_path = codebase_path || ENV.fetch("CHAT_CODEBASE_PATH", DEFAULT_CODEBASE_PATH)
  end

  # Start a new Claude session with an initial prompt.
  # Returns { session_id: String, response: String }
  def start_session(prompt:)
    cmd = build_command(streaming: false)
    output = run_claude(cmd, prompt)
    data = JSON.parse(output)

    {
      session_id: data["session_id"],
      response: data["result"] || ""
    }
  rescue JSON::ParserError => e
    Rails.logger.error("[ClaudeCliService] Failed to parse response: #{e.message}")
    raise ClaudeCliError, "Failed to parse Claude response"
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code"
  end

  # Send a message to an existing session and stream the response line by line.
  # Yields each raw JSON line from the subprocess.
  # Returns { session_id: String, response: String }
  def send_message_streaming(session_id:, message:, &block)
    cmd = build_command(session_id: session_id, streaming: true)
    full_response = ""
    current_session_id = session_id

    popen_streaming(cmd, message) do |line|
      block.call(line) if block_given?

      data = JSON.parse(line) rescue nil
      next unless data

      if data["type"] == "result"
        full_response = data["result"] || full_response
        current_session_id = data["session_id"] || current_session_id
      end
    end

    { session_id: current_session_id, response: full_response }
  rescue Errno::ENOENT
    raise ClaudeCliError, "Claude CLI not found"
  end

  class ClaudeCliError < StandardError; end

  private

  def build_command(session_id: nil, streaming: false)
    cmd = [CLAUDE_CMD, "-p"]

    if streaming
      cmd += ["--output-format", "stream-json", "--verbose"]
    else
      cmd += ["--output-format", "json"]
    end

    cmd += ["--resume", session_id] if session_id
    cmd += ["--add-dir", @codebase_path]
    cmd
  end

  def run_claude(cmd, message)
    IO.popen(cmd, "r+") do |io|
      io.write(message)
      io.close_write
      io.read
    end
  end

  def popen_streaming(cmd, message, &block)
    IO.popen(cmd, "r+") do |io|
      io.write(message)
      io.close_write
      io.each_line { |line| block.call(line.strip) if line.strip.present? }
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/services/claude_cli_service_test.rb`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add app/services/claude_cli_service.rb test/services/claude_cli_service_test.rb
git commit -m "feat: add ClaudeCliService for spawning Claude CLI subprocess"
```

---

## Chunk 3: Controller Layer (Routes + ChatSessionsController)

### Task 4: Add routes and create ChatSessionsController

**Files:**
- Modify: `config/routes.rb:71-76`
- Create: `app/controllers/chat_sessions_controller.rb`
- Create: `test/controllers/chat_sessions_controller_test.rb`

- [ ] **Step 1: Write controller tests**

Create `test/controllers/chat_sessions_controller_test.rb`:

```ruby
require "test_helper"

class ChatSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @task = tasks(:jira_task)
  end

  test "create returns existing active session" do
    session = chat_sessions(:one)
    post jira_task_chat_session_path(@task), as: :json
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal session.id, json["chat_session"]["id"]
    assert json["chat_session"]["messages"].is_a?(Array)
  end

  test "show returns session with messages" do
    get jira_task_chat_session_path(@task), as: :json
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal chat_sessions(:one).id, json["chat_session"]["id"]
    assert json["chat_session"]["messages"].length >= 1
  end

  test "show returns 404 when no active session" do
    chat_sessions(:one).update!(status: "closed")
    get jira_task_chat_session_path(@task), as: :json
    assert_response :not_found
  end

  test "create requires authentication" do
    sign_out
    post jira_task_chat_session_path(@task), as: :json
    assert_response :redirect
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/chat_sessions_controller_test.rb`
Expected: Error — routing or controller not found

- [ ] **Step 3: Add routes**

Modify `config/routes.rb` — replace the jira_tasks block (lines 71-76):

```ruby
resources :jira_tasks, only: [:index, :show] do
  collection do
    get :board_data
    post :refresh
  end
  resource :chat_session, only: [:create, :show] do
    post :message
  end
end
```

- [ ] **Step 4: Create the controller**

Create `app/controllers/chat_sessions_controller.rb`:

```ruby
class ChatSessionsController < ApplicationController
  include WorkspaceScoped
  include ActionController::Live  # Required for SSE streaming in message action; affects all actions but harmless for JSON responses

  before_action :require_employee!
  before_action :set_task

  def create
    @chat_session = ChatSession.find_active_for(@task, current_user)

    if @chat_session
      render json: session_json(@chat_session)
      return
    end

    service = ClaudeCliService.new
    prompt = build_initial_prompt

    begin
      result = service.start_session(prompt: prompt)
    rescue ClaudeCliService::ClaudeCliError => e
      render json: { error: e.message }, status: :service_unavailable
      return
    end

    unless result[:session_id].present?
      render json: { error: "Claude did not return a session ID" }, status: :service_unavailable
      return
    end

    @chat_session = ChatSession.create!(
      task: @task,
      workspace: current_workspace,
      user: current_user,
      claude_session_id: result[:session_id],
      codebase_path: ClaudeCliService::DEFAULT_CODEBASE_PATH
    )

    @chat_session.chat_messages.create!(
      role: "assistant",
      content: result[:response]
    )

    render json: session_json(@chat_session)
  end

  def show
    @chat_session = ChatSession.find_active_for(@task, current_user)

    if @chat_session
      render json: session_json(@chat_session)
    else
      render json: { error: "No active chat session" }, status: :not_found
    end
  end

  def message
    @chat_session = ChatSession.find_active_for(@task, current_user)

    unless @chat_session
      render json: { error: "No active chat session" }, status: :not_found
      return
    end

    user_content = params[:content].to_s.strip
    if user_content.blank?
      render json: { error: "Message content required" }, status: :unprocessable_entity
      return
    end

    @chat_session.chat_messages.create!(role: "user", content: user_content)

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    service = ClaudeCliService.new(codebase_path: @chat_session.codebase_path)
    full_response = ""

    begin
      result = service.send_message_streaming(
        session_id: @chat_session.claude_session_id,
        message: user_content
      ) do |line|
        data = JSON.parse(line) rescue nil
        next unless data

        if data["type"] == "assistant"
          text = data.dig("message", "content")&.filter_map { |c| c["text"] }&.join("")
          if text.present?
            full_response += text
            response.stream.write("data: #{text.to_json}\n\n")
          end
        elsif data["type"] == "result"
          full_response = data["result"] if data["result"].present?
          response.stream.write("data: #{{"done" => true}.to_json}\n\n")
        end
      end

      # Update session_id if it changed (e.g., resume failed, new session created)
      if result[:session_id] != @chat_session.claude_session_id
        @chat_session.update!(claude_session_id: result[:session_id])
      end

      @chat_session.chat_messages.create!(role: "assistant", content: full_response) if full_response.present?

    rescue ClaudeCliService::ClaudeCliError => e
      response.stream.write("data: #{{"error" => e.message}.to_json}\n\n")
    rescue IOError, Errno::EPIPE
      # Client disconnected — save what we have
      @chat_session.chat_messages.create!(role: "assistant", content: full_response) if full_response.present?
    ensure
      response.stream.close
    end
  end

  private

  def set_task
    @task = Task.joins(:project)
               .where(projects: { workspace_id: current_workspace.id })
               .find(params[:jira_task_id])
  end

  def build_initial_prompt
    desc = @task.description.presence || "No description"

    "You are helping with Jira ticket #{@task.external_reference}: " \
    "#{@task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, '')}.\n\n" \
    "Here is the ticket description:\n\n#{desc}\n\n" \
    "You have access to the codebase. " \
    "Acknowledge briefly what the ticket is about and ask what the user would like to work on."
  end

  def session_json(chat_session)
    {
      chat_session: {
        id: chat_session.id,
        claude_session_id: chat_session.claude_session_id,
        status: chat_session.status,
        messages: chat_session.chat_messages.ordered.map do |msg|
          { id: msg.id, role: msg.role, content: msg.content, created_at: msg.created_at }
        end
      }
    }
  end
end
```

- [ ] **Step 5: Run tests**

Run: `bin/rails test test/controllers/chat_sessions_controller_test.rb`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/chat_sessions_controller.rb test/controllers/chat_sessions_controller_test.rb
git commit -m "feat: add ChatSessionsController with create, show, and message actions"
```

---

## Chunk 4: Frontend — Stimulus Controller

### Task 5: Create task-chat Stimulus controller

**Files:**
- Create: `app/javascript/controllers/task_chat_controller.js`

- [ ] **Step 1: Create the Stimulus controller**

Create `app/javascript/controllers/task_chat_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["details", "taskContent", "chatPanel", "chatMessages", "chatInput",
                     "chatHeader", "breadcrumb", "chatBreadcrumb", "expandBtn"]
  static values = {
    state: { type: String, default: "normal" },
    createUrl: String,
    messageUrl: String,
    taskId: Number,
    hasSession: { type: Boolean, default: false }
  }

  connect() {
    this.abortController = null
    this.sidebar = document.querySelector("aside.m3-drawer-side")
    // Clean up chat state on Turbo navigation
    this.beforeVisitHandler = () => this.closeChat()
    document.addEventListener("turbo:before-visit", this.beforeVisitHandler)
  }

  disconnect() {
    this.abortIfStreaming()
    if (this.sidebar) this.sidebar.style.display = ""
    document.removeEventListener("turbo:before-visit", this.beforeVisitHandler)
  }

  // ---- State transitions ----

  async openChat() {
    if (this.stateValue !== "normal") return

    this.chatPanelTarget.classList.remove("hidden")
    this.stateValue = "sideBySide"
    this.applyState()

    if (!this.hasSessionValue) {
      await this.createSession()
    } else {
      await this.loadSession()
    }
  }

  closeChat() {
    this.abortIfStreaming()
    this.stateValue = "normal"
    this.applyState()
  }

  expandChat() {
    if (this.stateValue !== "sideBySide") return
    this.stateValue = "fullscreen"
    this.applyState()
  }

  shrinkChat() {
    if (this.stateValue !== "fullscreen") return
    this.stateValue = "sideBySide"
    this.applyState()
  }

  applyState() {
    const state = this.stateValue

    // Sidebar
    if (this.sidebar) {
      this.sidebar.style.display = state === "normal" ? "" : "none"
    }

    // Details panel
    if (this.hasDetailsTarget) {
      this.detailsTarget.style.display = state === "normal" ? "" : "none"
    }

    // Task content
    if (this.hasTaskContentTarget) {
      this.taskContentTarget.style.display = state === "fullscreen" ? "none" : ""
    }

    // Chat panel
    if (this.hasChatPanelTarget) {
      this.chatPanelTarget.classList.toggle("hidden", state === "normal")
      if (state === "fullscreen") {
        this.chatPanelTarget.style.width = "100%"
        this.chatPanelTarget.style.maxWidth = "720px"
        this.chatPanelTarget.style.margin = "0 auto"
        this.chatPanelTarget.style.borderLeft = "none"
      } else {
        this.chatPanelTarget.style.width = ""
        this.chatPanelTarget.style.maxWidth = ""
        this.chatPanelTarget.style.margin = ""
        this.chatPanelTarget.style.borderLeft = ""
      }
    }

    // Breadcrumbs
    if (this.hasBreadcrumbTarget) {
      this.breadcrumbTarget.style.display = state === "normal" ? "" : "none"
    }
    if (this.hasChatBreadcrumbTarget) {
      this.chatBreadcrumbTarget.style.display = state === "normal" ? "none" : ""
    }

    // Chat header (fullscreen compact bar)
    if (this.hasChatHeaderTarget) {
      this.chatHeaderTarget.style.display = state === "fullscreen" ? "" : "none"
    }

    // Expand/shrink button text
    if (this.hasExpandBtnTarget) {
      const isFullscreen = state === "fullscreen"
      this.expandBtnTarget.innerHTML = isFullscreen
        ? '<svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 9V4.5M9 9H4.5M9 9L3.75 3.75M9 15v4.5M9 15H4.5M9 15l-5.25 5.25M15 9h4.5M15 9V4.5M15 9l5.25-5.25M15 15h4.5M15 15v4.5m0-4.5l5.25 5.25" /></svg> Shrink'
        : '<svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M3.75 3.75v4.5m0-4.5h4.5m-4.5 0L9 9M3.75 20.25v-4.5m0 4.5h4.5m-4.5 0L9 15M20.25 3.75h-4.5m4.5 0v4.5m0-4.5L15 9m5.25 11.25h-4.5m4.5 0v-4.5m0 4.5L15 15" /></svg> Expand'
    }

    // Scroll chat to bottom
    if (state !== "normal" && this.hasChatMessagesTarget) {
      this.scrollToBottom()
    }
  }

  // ---- Chat operations ----

  async createSession() {
    try {
      this.showLoading()
      const response = await fetch(this.createUrlValue, {
        method: "POST",
        headers: this.headers()
      })
      const data = await response.json()

      if (data.error) {
        this.showError(data.error)
        return
      }

      this.hasSessionValue = true
      this.renderMessages(data.chat_session.messages)
    } catch (e) {
      this.showError("Failed to start chat session")
    }
  }

  async loadSession() {
    try {
      const response = await fetch(this.createUrlValue, { headers: this.headers() })

      if (response.ok) {
        const data = await response.json()
        this.renderMessages(data.chat_session.messages)
      }
    } catch (e) {
      // Ignore — session may not exist yet
    }
  }

  async sendMessage(event) {
    event?.preventDefault()
    const input = this.chatInputTarget
    const content = input.value.trim()
    if (!content) return

    input.value = ""
    input.disabled = true

    this.appendMessage("user", content)

    // Create placeholder for assistant response
    const assistantBubble = this.appendMessage("assistant", "")
    const textSpan = assistantBubble.querySelector("[data-chat-text]")

    this.abortController = new AbortController()

    try {
      const response = await fetch(this.messageUrlValue, {
        method: "POST",
        headers: { ...this.headers(), "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
        signal: this.abortController.signal
      })

      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ""

      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split("\n")
        buffer = lines.pop() // Keep incomplete line in buffer

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue
          const jsonStr = line.slice(6)

          try {
            const data = JSON.parse(jsonStr)
            if (data.done) {
              // Stream complete
            } else if (data.error) {
              textSpan.textContent += `\n[Error: ${data.error}]`
            } else {
              // data is a text chunk
              textSpan.textContent += data
            }
          } catch {
            // Not valid JSON, skip
          }
        }

        this.scrollToBottom()
      }
    } catch (e) {
      if (e.name !== "AbortError") {
        textSpan.textContent += "\n[Connection interrupted]"
      }
    } finally {
      input.disabled = false
      input.focus()
      this.abortController = null
      this.scrollToBottom()
    }
  }

  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.sendMessage()
    }
  }

  // ---- DOM helpers ----

  appendMessage(role, content) {
    const wrapper = document.createElement("div")
    wrapper.className = role === "user"
      ? "flex justify-end"
      : "flex justify-start"

    const bubble = document.createElement("div")
    bubble.className = role === "user"
      ? "chat-bubble chat-bubble-user"
      : "chat-bubble chat-bubble-assistant"

    const textSpan = document.createElement("span")
    textSpan.setAttribute("data-chat-text", "")
    textSpan.textContent = content
    bubble.appendChild(textSpan)

    wrapper.appendChild(bubble)
    this.chatMessagesTarget.appendChild(wrapper)
    this.scrollToBottom()

    return wrapper
  }

  renderMessages(messages) {
    this.chatMessagesTarget.innerHTML = ""
    messages.forEach(msg => this.appendMessage(msg.role, msg.content))
  }

  showLoading() {
    this.chatMessagesTarget.innerHTML = '<div class="flex justify-center py-8"><span class="text-sm" style="color: var(--color-outline)">Starting chat session...</span></div>'
  }

  showError(message) {
    this.chatMessagesTarget.innerHTML = `<div class="flex justify-center py-8"><span class="text-sm" style="color: var(--color-error)">${message}</span></div>`
  }

  scrollToBottom() {
    if (this.hasChatMessagesTarget) {
      this.chatMessagesTarget.scrollTop = this.chatMessagesTarget.scrollHeight
    }
  }

  abortIfStreaming() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  headers() {
    return {
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      "Accept": "application/json"
    }
  }
}
```

- [ ] **Step 2: Verify the controller is auto-loaded**

The controller file name `task_chat_controller.js` will auto-register as `task-chat` via the eager loading in `app/javascript/controllers/index.js`. No additional registration needed.

- [ ] **Step 3: Commit**

```bash
git add app/javascript/controllers/task_chat_controller.js
git commit -m "feat: add task-chat Stimulus controller with 3-state UI management"
```

---

## Chunk 5: Views — Chat UI Integration

### Task 6: Update show view and layout, create chat partials

**Files:**
- Modify: `app/views/layouts/application.html.erb:48` — add id to aside
- Modify: `app/views/jira_tasks/show.html.erb` — wrap in controller, add chat button + panel
- Create: `app/views/jira_tasks/_chat_panel.html.erb`

- [ ] **Step 1: Add id to sidebar in layout**

Modify `app/views/layouts/application.html.erb` line 48 — add `id="app-sidebar"` to the aside tag. Change:

```erb
<aside class="m3-drawer-side m3-nav-rail w-64 lg:block flex-shrink-0 h-full flex flex-col overflow-y-auto">
```

to:

```erb
<aside id="app-sidebar" class="m3-drawer-side m3-nav-rail w-64 lg:block flex-shrink-0 h-full flex flex-col overflow-y-auto">
```

- [ ] **Step 2: Create chat panel partial**

Create `app/views/jira_tasks/_chat_panel.html.erb`:

```erb
<%# Chat panel — shown in sideBySide and fullscreen states %>
<div class="hidden flex flex-col h-full"
     data-task-chat-target="chatPanel"
     style="background: var(--color-surface-container-low); border-left: 1px solid var(--color-outline-variant); min-width: 0; width: 45%; flex-shrink: 0;">

  <%# Chat header %>
  <div class="flex items-center justify-between px-4 py-3"
       style="border-bottom: 1px solid var(--color-outline-variant)">
    <div class="flex items-center gap-2">
      <span class="w-2 h-2 rounded-full" style="background: var(--color-primary)"></span>
      <span class="text-sm font-semibold" style="color: var(--color-on-surface)">Claude Code</span>
      <span class="text-xs" style="color: var(--color-outline)">~/work/elvium</span>
    </div>
    <button class="flex items-center gap-1.5 text-xs px-2 py-1 rounded-md transition-colors"
            style="color: var(--color-on-surface-variant); background: var(--color-surface-container)"
            data-task-chat-target="expandBtn"
            data-action="click->task-chat#expandChat">
      <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M3.75 3.75v4.5m0-4.5h4.5m-4.5 0L9 9M3.75 20.25v-4.5m0 4.5h4.5m-4.5 0L9 15M20.25 3.75h-4.5m4.5 0v4.5m0-4.5L15 9m5.25 11.25h-4.5m4.5 0v-4.5m0 4.5L15 15" /></svg>
      Expand
    </button>
  </div>

  <%# Context banner %>
  <div class="px-4 py-2 text-xs" style="border-bottom: 1px solid var(--color-outline-variant); border-left: 3px solid var(--color-primary); color: var(--color-outline); background: var(--color-surface-container)">
    Context: <%= task.external_reference %> + ~/work/elvium codebase
  </div>

  <%# Messages area %>
  <div class="flex-1 overflow-y-auto px-4 py-4 space-y-3"
       data-task-chat-target="chatMessages">
    <%# Messages rendered by Stimulus controller %>
  </div>

  <%# Input area %>
  <div class="px-4 py-3" style="border-top: 1px solid var(--color-outline-variant)">
    <form class="flex gap-2" data-action="submit->task-chat#sendMessage">
      <input type="text"
             class="flex-1 px-4 py-2.5 rounded-full text-sm outline-none"
             style="background: var(--color-surface-container); color: var(--color-on-surface); border: 1px solid var(--color-outline-variant)"
             placeholder="Ask Claude about this task..."
             data-task-chat-target="chatInput"
             data-action="keydown->task-chat#handleKeydown"
             autocomplete="off">
      <button type="submit"
              class="w-10 h-10 rounded-full flex items-center justify-center flex-shrink-0 transition-colors"
              style="background: var(--color-primary); color: var(--color-on-primary)">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
          <path stroke-linecap="round" stroke-linejoin="round" d="M4.5 10.5L12 3m0 0l7.5 7.5M12 3v18" />
        </svg>
      </button>
    </form>
  </div>
</div>
```

- [ ] **Step 3: Update show view**

Replace the entire content of `app/views/jira_tasks/show.html.erb` with:

```erb
<% content_for(:title, "#{@task.external_reference} — #{@task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, '')}") %>
<% content_for(:full_width, true) %>

<div class="space-y-5"
     data-controller="task-chat"
     data-task-chat-create-url-value="<%= jira_task_chat_session_path(@task) %>"
     data-task-chat-message-url-value="<%= message_jira_task_chat_session_path(@task) %>"
     data-task-chat-task-id-value="<%= @task.id %>"
     data-task-chat-has-session-value="<%= ChatSession.find_active_for(@task, current_user).present? %>">

  <%# Normal breadcrumb — visible in normal state %>
  <div class="flex items-center gap-2 text-sm" data-task-chat-target="breadcrumb" style="color: var(--color-on-surface-variant)">
    <%= link_to "Jira Tasks", jira_tasks_path(project_id: @selected_project&.id, board_id: @selected_board&.id, sprint_id: @selected_sprint&.id), class: "hover:underline", style: "color: var(--color-primary)" %>
    <span>/</span>
    <span style="color: var(--color-on-surface)"><%= @task.external_reference %></span>
    <button class="ml-auto flex items-center gap-1.5 text-xs px-3 py-1.5 rounded-lg transition-colors"
            style="background: rgba(var(--color-primary-rgb, 76,105,54), 0.1); color: var(--color-primary); border: 1px solid rgba(var(--color-primary-rgb, 76,105,54), 0.2)"
            data-action="click->task-chat#openChat">
      <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.129.166 2.27.293 3.423.379.35.026.67.21.865.501L12 21l2.755-4.133a1.14 1.14 0 01.865-.501 48.172 48.172 0 003.423-.379c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0012 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018z" /></svg>
      Chat with AI
    </button>
  </div>

  <%# Chat breadcrumb — visible in sideBySide and fullscreen states %>
  <div class="flex items-center gap-3 text-sm" data-task-chat-target="chatBreadcrumb" style="display: none; color: var(--color-on-surface-variant)">
    <button class="flex items-center gap-1.5 text-xs px-3 py-1.5 rounded-lg transition-colors"
            style="background: var(--color-surface-container); color: var(--color-on-surface-variant); border: 1px solid var(--color-outline-variant)"
            data-action="click->task-chat#closeChat">
      <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M10.5 19.5L3 12m0 0l7.5-7.5M3 12h18" /></svg>
      Close Chat
    </button>
    <span style="color: var(--color-on-surface)"><%= @task.external_reference %></span>
  </div>

  <%# Fullscreen chat header — only visible in fullscreen %>
  <div class="flex items-center gap-3 px-4 py-2 rounded-lg"
       data-task-chat-target="chatHeader"
       style="display: none; background: var(--color-surface-container); border: 1px solid var(--color-outline-variant)">
    <span class="text-sm font-semibold" style="color: var(--color-primary)"><%= @task.external_reference %></span>
    <span class="text-sm font-medium truncate" style="color: var(--color-on-surface)">
      <%= @task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, '') %>
    </span>
    <div class="ml-auto flex items-center gap-2">
      <span class="text-xs px-2 py-0.5 rounded-full" style="background: var(--color-secondary-container); color: var(--color-on-secondary-container)">
        <%= @task.jira_status_name %>
      </span>
    </div>
  </div>

  <div class="flex gap-6" style="min-height: calc(100vh - 12rem);">
    <%# Main content %>
    <div class="flex-1 min-w-0" data-task-chat-target="taskContent">
      <div class="m3-card-outlined p-6 space-y-5">
        <%# Header %>
        <div>
          <div class="flex items-center gap-2 mb-2">
            <span class="text-sm font-semibold" style="color: var(--color-primary)">
              <%= @task.external_reference %>
            </span>
          </div>
          <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)">
            <%= @task.name.sub(/\A#{Regexp.escape(@task.external_reference.to_s)}\s*/, '') %>
          </h1>
        </div>

        <%# Status badges %>
        <div class="flex items-center gap-2">
          <span class="text-xs px-2.5 py-1 rounded-full font-medium" style="background: var(--color-secondary-container); color: var(--color-on-secondary-container)">
            <%= @task.jira_status_name %>
          </span>
          <% if @task.issue_type.present? %>
            <span class="text-xs px-2.5 py-1 rounded-full font-medium" style="background: var(--color-tertiary-container); color: var(--color-on-tertiary-container)">
              <%= @task.issue_type %>
            </span>
          <% end %>
        </div>

        <%# Description %>
        <% if @task.description.present? %>
          <div>
            <h2 class="text-sm font-semibold mb-3" style="color: var(--color-on-surface-variant)">Description</h2>
            <div class="adf-content text-sm leading-relaxed p-4 rounded-lg" style="color: var(--color-on-surface); background: var(--color-surface-container-low)">
              <% if @task.description_adf.present? %>
                <%= adf_to_html(@task.description_adf) %>
              <% else %>
                <div class="whitespace-pre-wrap"><%= @task.description %></div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>

    <%# Details sidebar — visible in normal state only %>
    <div class="w-72 flex-shrink-0" data-task-chat-target="details">
      <div class="m3-card-outlined p-5 space-y-4 sticky top-5">
        <h2 class="text-sm font-semibold" style="color: var(--color-on-surface-variant)">Details</h2>

        <div class="space-y-3 text-sm">
          <div>
            <dt class="text-xs mb-0.5" style="color: var(--color-outline)">Assignee</dt>
            <dd class="font-medium" style="color: var(--color-on-surface)">
              <% if @task.assignee_name.present? || @task.assignee_email.present? %>
                <div class="flex items-center gap-2">
                  <div class="m3-avatar" style="width: 24px; height: 24px; font-size: 0.6rem">
                    <%= (@task.assignee_name || @task.assignee_email).split(/[\s@]/).map(&:first).join.first(2).upcase %>
                  </div>
                  <%= @task.assignee_name || @task.assignee_email %>
                </div>
              <% else %>
                Unassigned
              <% end %>
            </dd>
          </div>

          <div>
            <dt class="text-xs mb-0.5" style="color: var(--color-outline)">Reporter</dt>
            <dd class="font-medium" style="color: var(--color-on-surface)"><%= @task.reporter_name || @task.reporter_email || "—" %></dd>
          </div>

          <div>
            <dt class="text-xs mb-0.5" style="color: var(--color-outline)">Priority</dt>
            <dd class="font-medium flex items-center gap-1" style="color: var(--color-on-surface)">
              <% if @task.priority.present? %>
                <% case @task.priority.downcase %>
                <% when "highest", "high" %>
                  <svg class="h-4 w-4" style="color: var(--color-error)" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M14.77 12.79a.75.75 0 01-1.06-.02L10 8.832 6.29 12.77a.75.75 0 11-1.08-1.04l4.25-4.5a.75.75 0 011.08 0l4.25 4.5a.75.75 0 01-.02 1.06z" clip-rule="evenodd" /></svg>
                <% when "medium" %>
                  <svg class="h-4 w-4" style="color: var(--color-tertiary)" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M3 10a.75.75 0 01.75-.75h12.5a.75.75 0 010 1.5H3.75A.75.75 0 013 10z" clip-rule="evenodd" /></svg>
                <% when "low", "lowest" %>
                  <svg class="h-4 w-4" style="color: var(--color-primary)" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M5.23 7.21a.75.75 0 011.06.02L10 11.168l3.71-3.938a.75.75 0 111.08 1.04l-4.25 4.5a.75.75 0 01-1.08 0l-4.25-4.5a.75.75 0 01.02-1.06z" clip-rule="evenodd" /></svg>
                <% end %>
                <%= @task.priority %>
              <% else %>
                —
              <% end %>
            </dd>
          </div>

          <div>
            <dt class="text-xs mb-0.5" style="color: var(--color-outline)">Sprint</dt>
            <dd class="font-medium" style="color: var(--color-on-surface)"><%= @task.sprint_name || "—" %></dd>
          </div>

          <% if @task.labels.present? %>
            <% labels = begin; JSON.parse(@task.labels); rescue; []; end %>
            <% if labels.any? %>
              <div>
                <dt class="text-xs mb-1" style="color: var(--color-outline)">Labels</dt>
                <dd class="flex flex-wrap gap-1">
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
              <dt class="text-xs mb-0.5" style="color: var(--color-outline)">Estimate</dt>
              <dd class="font-medium" style="color: var(--color-on-surface)">
                <%= @task.time_estimate_seconds / 3600 %>h <%= (@task.time_estimate_seconds % 3600) / 60 %>m
              </dd>
            </div>
          <% end %>
        </div>

        <%# Chat button in details %>
        <div class="pt-2 space-y-2">
          <button class="w-full inline-flex items-center justify-center gap-2 px-4 py-2.5 rounded-lg text-sm font-medium transition-colors"
                  style="background: rgba(var(--color-primary-rgb, 76,105,54), 0.1); color: var(--color-primary); border: 1px solid rgba(var(--color-primary-rgb, 76,105,54), 0.2)"
                  data-action="click->task-chat#openChat">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.129.166 2.27.293 3.423.379.35.026.67.21.865.501L12 21l2.755-4.133a1.14 1.14 0 01.865-.501 48.172 48.172 0 003.423-.379c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0012 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018z" /></svg>
            Chat with AI
          </button>
          <a href="<%= @task.external_url %>" target="_blank" rel="noopener"
             class="m3-btn m3-btn-filled w-full inline-flex items-center justify-center gap-2">
            View in Jira
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
              <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
            </svg>
          </a>
        </div>
      </div>
    </div>

    <%# Chat panel (initially hidden) %>
    <%= render "jira_tasks/chat_panel", task: @task %>
  </div>
</div>
```

- [ ] **Step 4: Add chat bubble CSS to the app stylesheet**

Find the app stylesheet and add chat-specific styles. Check where custom CSS lives:

Run: `ls app/assets/stylesheets/`

Then append to the main stylesheet (likely `app/assets/stylesheets/application.css` or similar):

```css
/* Chat bubbles */
.chat-bubble {
  max-width: 85%;
  padding: 0.625rem 0.875rem;
  border-radius: 0.875rem;
  font-size: 0.8125rem;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-word;
}

.chat-bubble-user {
  background: var(--color-primary);
  color: var(--color-on-primary);
  border-bottom-right-radius: 0.25rem;
}

.chat-bubble-assistant {
  background: var(--color-surface-container-highest);
  color: var(--color-on-surface);
  border-bottom-left-radius: 0.25rem;
}

.chat-bubble-assistant code {
  font-family: 'JetBrains Mono', monospace;
  font-size: 0.75rem;
  background: var(--color-surface-container);
  padding: 0.125rem 0.375rem;
  border-radius: 0.25rem;
}

.chat-bubble-assistant pre {
  background: var(--color-surface-container);
  padding: 0.75rem;
  border-radius: 0.5rem;
  overflow-x: auto;
  margin: 0.5rem 0;
}

.chat-bubble-assistant pre code {
  background: none;
  padding: 0;
}
```

- [ ] **Step 5: Run the full test suite to ensure nothing is broken**

Run: `bin/rails test`
Expected: All existing tests pass. The show view test may need route helper updates.

- [ ] **Step 6: Verify routes are correct**

Run: `bin/rails routes | grep chat`
Expected output should include:
```
jira_task_chat_session      POST   /jira_tasks/:jira_task_id/chat_session(.:format)           chat_sessions#create
                            GET    /jira_tasks/:jira_task_id/chat_session(.:format)           chat_sessions#show
message_jira_task_chat_session POST /jira_tasks/:jira_task_id/chat_session/message(.:format)  chat_sessions#message
```

- [ ] **Step 7: Commit**

```bash
git add app/views/layouts/application.html.erb app/views/jira_tasks/show.html.erb app/views/jira_tasks/_chat_panel.html.erb app/assets/stylesheets/
git commit -m "feat: add chat mode UI to Jira task show view with 3-state layout"
```

---

## Chunk 6: Integration Testing and Polish

### Task 7: Manual testing and fixes

- [ ] **Step 1: Start the Rails server**

Run: `bin/rails server`

- [ ] **Step 2: Navigate to a task view**

Open: `http://127.0.0.1:3000/jira_tasks/20?board_id=2&project_id=2&sprint_id=51`

Verify:
- "Chat with AI" button appears in breadcrumb area (right-aligned)
- "Chat with AI" button appears in details sidebar (above "View in Jira")
- Page looks identical to before otherwise

- [ ] **Step 3: Test side-by-side state**

Click "Chat with AI" button. Verify:
- Left navigation sidebar disappears
- Details panel disappears
- Chat panel appears on the right (~45% width)
- Breadcrumb changes to "Close Chat" + ticket reference
- Chat shows loading state, then Claude's initial response
- "Expand" button visible in chat header

- [ ] **Step 4: Test sending a message**

Type a message and press Enter. Verify:
- User message appears immediately (right-aligned, primary color bubble)
- Assistant response streams in (left-aligned, surface color bubble)
- Input is disabled during streaming, re-enabled after

- [ ] **Step 5: Test fullscreen state**

Click "Expand". Verify:
- Task description card disappears
- Chat takes full width (centered, max-width 720px)
- Compact header shows ticket reference, title, status
- "Shrink" button replaces "Expand"

- [ ] **Step 6: Test shrink back**

Click "Shrink". Verify:
- Returns to side-by-side layout
- Task description card reappears

- [ ] **Step 7: Test close chat**

Click "Close Chat". Verify:
- Returns to normal layout
- Left sidebar reappears
- Details panel reappears
- Normal breadcrumb reappears

- [ ] **Step 8: Test returning to existing chat**

Click "Chat with AI" again. Verify:
- Previous messages are loaded from DB
- No new Claude session is created
- Can continue the conversation

- [ ] **Step 9: Fix any issues found during manual testing**

Address any CSS, layout, or functionality issues discovered.

- [ ] **Step 10: Commit final fixes**

```bash
git add -A
git commit -m "fix: polish chat mode layout and fix issues from manual testing"
```
