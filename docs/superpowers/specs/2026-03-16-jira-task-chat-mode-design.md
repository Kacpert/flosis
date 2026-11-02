# Jira Task Chat Mode

## Summary

Add an AI chat mode to the Jira task detail view (`/jira_tasks/:id`). When activated, the left navigation and right details panel hide, and a chat panel opens on the right side where the user can converse with Claude Code. Claude has access to the ticket description and the project's codebase.

**Deployment context:** This is a single-user local development tool. The Rails server and Claude CLI run on the same machine under the same user account. Multi-user/production deployment is out of scope.

## UI States

Three states managed by a Stimulus controller (`task-chat`):

### State 1: Normal View
- Current layout unchanged
- "Chat with AI" button added in two places:
  - In the Details sidebar card (below labels/estimate, above "View in Jira")
  - In the breadcrumb area (right-aligned button next to `Jira Tasks / DEV-799`)
- Clicking either button transitions to State 2

### State 2: Side-by-Side Chat
- Left navigation sidebar (`aside.m3-drawer-side`) hidden
- Right details panel replaced by chat panel
- Breadcrumb area: "Jira Tasks / DEV-799" replaced by "Close Chat" button + ticket reference
- Task description card remains visible on the left
- Chat panel on the right (~45% width) with:
  - Header: green dot + "Claude Code" label + "Expand" button
  - Context banner: "Context: DEV-XXX + work/elvium codebase"
  - Message thread (assistant messages left-aligned, user messages right-aligned)
  - Input field with send button at the bottom
- Clicking "Close Chat" returns to State 1
- Clicking "Expand" transitions to State 3

### State 3: Fullscreen Chat
- Task description card also hidden
- Compact header bar: "Close Chat" button + DEV-XXX + ticket title + status badge + "Shrink" button
- Chat takes full width (max-width: 720px, centered)
- Same chat thread and input as State 2
- Clicking "Shrink" returns to State 2
- Clicking "Close Chat" returns to State 1

## Data Model

### ChatSession
- `id` (primary key)
- `task_id` (foreign key to tasks, indexed)
- `workspace_id` (foreign key to workspaces, indexed) — denormalized from task.project.workspace for query convenience
- `user_id` (foreign key to users, indexed)
- `claude_session_id` (string) — the UUID returned by `claude -p` for session resumption
- `codebase_path` (string) — absolute path to the codebase directory (e.g., `/Users/kacper/work/elvium`)
- `status` (string, default: "active") — "active" or "closed"
- `timestamps`
- Unique index on `[task_id, user_id, status]` where status = "active" (one active session per task+user)

### ChatMessage
- `id` (primary key)
- `chat_session_id` (foreign key to chat_sessions, indexed)
- `role` (string) — "user", "assistant", or "system"
- `content` (text)
- `timestamps`

### Associations
- `Task has_many :chat_sessions`
- `ChatSession belongs_to :task, :workspace, :user`
- `ChatSession has_many :chat_messages`
- `ChatMessage belongs_to :chat_session`

## Backend

### Configuration

Codebase path is configured via environment variable with a default:

```ruby
# Default codebase path, overridable per-session in the future
CHAT_CODEBASE_PATH = ENV.fetch("CHAT_CODEBASE_PATH", File.expand_path("~/work/elvium"))
```

### Controller: `ChatSessionsController`

**Routes** (nested under jira_tasks):
```ruby
resources :jira_tasks, only: [:index, :show] do
  resource :chat_session, only: [:create, :show] do
    post :message
  end
end
```

Singular `resource` because there is one active session per task+user. The `create` action finds-or-creates.

**Actions:**

#### `create` (POST /jira_tasks/:jira_task_id/chat_session)
1. Find or create a `ChatSession` for this task + current user (status: "active")
2. If existing session found, return it with messages (same as `show`)
3. If new session, spawn first Claude call with ticket context via stdin pipe:
   ```ruby
   cmd = ["claude", "-p", "--output-format", "json", "--add-dir", codebase_path]
   prompt = "You are helping with Jira ticket #{reference}: #{title}. " \
            "Here is the description:\n\n#{description}\n\n" \
            "You have access to the codebase at #{codebase_path}. " \
            "Acknowledge briefly and ask what the user would like to work on."

   result = IO.popen(cmd, "r+") do |io|
     io.write(prompt)
     io.close_write
     io.read
   end
   ```
4. Parse JSON response, save `claude_session_id` from result
5. Save assistant response as `ChatMessage`
6. Return chat session with initial message as JSON

#### `show` (GET /jira_tasks/:jira_task_id/chat_session)
- Return existing chat session with all messages for display on page load
- Used when user returns to a task that already has a chat session

#### `message` (POST /jira_tasks/:jira_task_id/chat_session/message)
1. Save user message as `ChatMessage`
2. Use `fetch` with `ReadableStream` on the frontend — the POST itself is the streaming response:
   ```ruby
   cmd = ["claude", "-p", "--output-format", "stream-json", "--verbose",
          "--resume", chat_session.claude_session_id,
          "--add-dir", chat_session.codebase_path]
   ```
3. Pipe user message via stdin (array form of `IO.popen` — no shell interpolation):
   ```ruby
   IO.popen(cmd, "r+") do |io|
     io.write(params[:content])
     io.close_write
     io.each_line do |line|
       # parse and stream to client
     end
   end
   ```
4. Stream response via ActionController::Live (SSE)
5. Save complete assistant response as `ChatMessage` when done
6. Close SSE connection

### Streaming Implementation

The `message` action is the SSE endpoint. The frontend uses `fetch()` with a `ReadableStream` reader to consume the streaming POST response (not a separate EventSource connection).

```ruby
include ActionController::Live

def message
  response.headers["Content-Type"] = "text/event-stream"
  response.headers["Cache-Control"] = "no-cache"
  response.headers["X-Accel-Buffering"] = "no"

  chat_session = find_chat_session
  ChatMessage.create!(chat_session: chat_session, role: "user", content: params[:content])

  full_response = ""
  cmd = ["claude", "-p", "--output-format", "stream-json", "--verbose",
         "--resume", chat_session.claude_session_id,
         "--add-dir", chat_session.codebase_path]

  IO.popen(cmd, "r+") do |io|
    io.write(params[:content])
    io.close_write
    io.each_line do |line|
      data = JSON.parse(line) rescue next
      if data["type"] == "assistant"
        text = data.dig("message", "content")&.map { |c| c["text"] }&.compact&.join("")
        if text.present?
          full_response += text
          response.stream.write("data: #{text.to_json}\n\n")
        end
      elsif data["type"] == "result"
        full_response = data["result"] if data["result"].present?
        response.stream.write("data: #{{"done" => true}.to_json}\n\n")
      end
    end
  end

  ChatMessage.create!(chat_session: chat_session, role: "assistant", content: full_response)
rescue IOError, Errno::EPIPE
  # Client disconnected
rescue => e
  response.stream.write("data: #{{"error" => e.message}.to_json}\n\n") rescue nil
ensure
  response.stream.close
end
```

### Error Handling

- **Claude CLI not found:** Rescue `Errno::ENOENT` from `IO.popen`, return JSON error `{ error: "Claude CLI not installed" }`
- **Subprocess crash/timeout:** If the process exits non-zero or produces no `result` event, send an SSE error event and save a system message noting the failure
- **Invalid/expired session ID:** If `--resume` fails, Claude will start a fresh session. Capture the new `session_id` from the result and update the `ChatSession` record
- **Client disconnects mid-stream:** `IOError`/`Errno::EPIPE` caught in ensure block, response stream closed gracefully. The assistant's partial response is still saved.

### Security
- All commands use array form `IO.popen(["claude", ...], "r+")` — no shell interpolation
- User message content passed via stdin pipe, never interpolated into command strings
- Chat sessions scoped to current workspace + user

## Frontend

### Stimulus Controller: `task-chat`

**Scope:** The controller is placed on a wrapper `div` inside the `<main>` tag on the show view. To hide the left nav sidebar, the controller uses `document.querySelector("aside.m3-drawer-side")` directly, since the sidebar lives in the layout outside the controller's element. This is acceptable for a page-level layout concern.

**Targets:**
- `details` — the right details panel
- `taskContent` — the main task description card
- `chatPanel` — the chat panel container
- `chatMessages` — the message thread container
- `chatInput` — the text input field
- `chatHeader` — the compact header (fullscreen mode)
- `breadcrumb` — the breadcrumb area
- `expandBtn` — expand/shrink toggle button

**Values:**
- `state` (String) — "normal", "sideBySide", "fullscreen"
- `sessionUrl` (String) — URL for the chat session endpoints
- `taskId` (Number)

**Methods:**
- `openChat()` — create/load session, transition to side-by-side
- `closeChat()` — transition back to normal
- `expandChat()` — transition to fullscreen
- `shrinkChat()` — transition back to side-by-side
- `sendMessage()` — POST user message, read streaming response via `fetch` + `ReadableStream`
- `appendMessage(role, content)` — add message bubble to thread
- `streamResponse(response)` — read the fetch response stream, progressively render assistant text
- `disconnect()` — cleanup: abort any in-flight fetch, restore sidebar visibility

**State Transitions:**
```
normal → openChat() → sideBySide
sideBySide → expandChat() → fullscreen
fullscreen → shrinkChat() → sideBySide
sideBySide|fullscreen → closeChat() → normal
```

**CSS approach:** Toggle data attributes on the controller element (e.g., `data-chat-state="sideBySide"`). Child elements use CSS selectors like `[data-chat-state="sideBySide"] [data-task-chat-target="details"] { display: none }`.

**Turbo compatibility:**
- The `disconnect()` lifecycle method aborts any in-flight fetch request and restores sidebar visibility
- The controller's `connect()` checks if there's an existing session and restores state if needed
- `beforeunload` / `turbo:before-visit` listeners ensure cleanup

### Streaming via Fetch

The frontend uses `fetch()` to POST the message and reads the SSE-formatted response as a stream:

```javascript
async sendMessage() {
  const content = this.chatInputTarget.value
  this.appendMessage("user", content)
  this.chatInputTarget.value = ""

  const response = await fetch(this.messageUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken },
    body: JSON.stringify({ content }),
    signal: this.abortController.signal
  })

  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let assistantContent = ""

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    const text = decoder.decode(value)
    // Parse SSE "data: ..." lines, append to assistant bubble
  }
}
```

### Chat UI Styling

- Chat panel background: `var(--color-surface-container-low)` with subtle left border
- User messages: `var(--color-primary)` background, white text, right-aligned, rounded bubbles
- Assistant messages: `var(--color-surface-container-highest)` background, left-aligned, rounded bubbles
- Code blocks in assistant messages: monospace, darker background
- Input: pill-shaped with circular send button using primary color
- Markdown rendering: use a simple custom renderer (bold via `**`, inline code via backticks, code blocks via triple backticks, lists). No external library needed for basic formatting. If richer rendering is needed later, `marked` (available via CDN/importmap) can be added.

## Process Flow

### First Chat Open
1. User clicks "Chat with AI"
2. Frontend sends POST to create chat session
3. Backend spawns Claude with ticket context via stdin, gets initial greeting
4. Frontend transitions to side-by-side, shows greeting message

### Subsequent Messages
1. User types message, presses Enter or clicks send
2. Message immediately appears in chat (user bubble)
3. Frontend sends POST to message endpoint (fetch with streaming)
4. Backend spawns `claude -p --resume` with the message via stdin
5. Streaming response delivered via SSE-formatted body
6. Assistant message bubble grows as tokens arrive
7. When stream completes, message is finalized

### Returning to Existing Chat
1. User navigates to task that has an active chat session
2. "Chat with AI" button shows indicator (e.g., dot or message count)
3. On click, existing messages loaded from DB and displayed
4. New messages resume the Claude session via `--resume`

### Error States
- If Claude CLI fails, show an error message in the chat with a "Retry" button
- If streaming is interrupted, save partial response and show "Response interrupted" indicator
- If session resume fails, the new session ID is captured and updated transparently

## Testing

- Model tests: ChatSession and ChatMessage associations, validations, scoping, unique active session constraint
- Controller tests: create session, send message, error handling, authorization (workspace scoping)
- System tests: open chat, send message, close chat, expand/shrink transitions
- Mock the Claude CLI subprocess in tests using a fake command that returns expected JSON format
