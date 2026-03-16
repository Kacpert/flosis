# Jira Task Chat Mode

## Summary

Add an AI chat mode to the Jira task detail view (`/jira_tasks/:id`). When activated, the left navigation and right details panel hide, and a chat panel opens on the right side where the user can converse with Claude Code. Claude has access to the ticket description and the `~/work/elvium` codebase.

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
- `workspace_id` (foreign key to workspaces, indexed)
- `user_id` (foreign key to users, indexed)
- `claude_session_id` (string) — the UUID returned by `claude -p` for session resumption
- `status` (string, default: "active") — "active" or "closed"
- `timestamps`

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

### Controller: `ChatSessionsController`

**Routes** (nested under jira_tasks):
```ruby
resources :jira_tasks, only: [:index, :show] do
  resource :chat_session, only: [:create, :show] do
    post :message
  end
end
```

**Actions:**

#### `create` (POST /jira_tasks/:jira_task_id/chat_session)
1. Find or create a `ChatSession` for this task + current user
2. If new session, spawn first Claude call with ticket context:
   ```bash
   claude -p --output-format json --add-dir ~/work/elvium \
     "You are helping with Jira ticket {reference}: {title}. Here is the description: {description}. You have access to the codebase at ~/work/elvium. Acknowledge briefly and ask what the user would like to work on."
   ```
3. Parse JSON response, save `claude_session_id` from result
4. Save assistant response as `ChatMessage`
5. Return chat session with initial message (Turbo Stream or JSON)

#### `show` (GET /jira_tasks/:jira_task_id/chat_session)
- Return existing chat session with all messages for display on page load
- Used when user returns to a task that already has a chat session

#### `message` (POST /jira_tasks/:jira_task_id/chat_session/message)
1. Save user message as `ChatMessage`
2. Spawn Claude subprocess:
   ```bash
   claude -p --output-format stream-json --verbose \
     --resume {claude_session_id} \
     --add-dir ~/work/elvium \
     "{user_message}"
   ```
3. Stream response via SSE (ActionController::Live):
   - Read stdout line by line
   - For lines with `"type":"assistant"`, extract text content and stream to browser
   - For the `"type":"result"` line, finalize
4. Save complete assistant response as `ChatMessage`
5. Close SSE connection

### SSE Streaming

Use `ActionController::Live` with `text/event-stream` content type:

```ruby
response.headers["Content-Type"] = "text/event-stream"
response.headers["Cache-Control"] = "no-cache"

# Stream chunks as they arrive from Claude subprocess
IO.popen(claude_command, "r") do |io|
  io.each_line do |line|
    data = JSON.parse(line)
    if data["type"] == "assistant"
      text = extract_text(data)
      response.stream.write("data: #{text.to_json}\n\n")
    elsif data["type"] == "result"
      response.stream.write("data: {\"done\": true}\n\n")
    end
  end
end
```

### Security Considerations
- Chat sessions scoped to current workspace + user
- User message content sanitized (no shell injection — message passed via stdin pipe, not command argument)
- Claude subprocess runs with user's own claude CLI credentials

## Frontend

### Stimulus Controller: `task-chat`

**Targets:**
- `sidebar` — the left navigation aside
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
- `sendMessage()` — POST user message, start SSE listener for response
- `appendMessage(role, content)` — add message bubble to thread
- `streamResponse()` — connect to SSE endpoint, progressively render assistant response

**State Transitions:**
```
normal → openChat() → sideBySide
sideBySide → expandChat() → fullscreen
fullscreen → shrinkChat() → sideBySide
sideBySide|fullscreen → closeChat() → normal
```

**CSS approach:** Toggle CSS classes on the body or a wrapper element. The left nav, details panel, and task content respond to data attributes or classes to show/hide with transitions.

### Layout Integration

The show view template gets a `data-controller="task-chat"` wrapper. The layout's left sidebar gets a `data-task-chat-target="sidebar"` attribute. State changes toggle visibility classes.

Since the left nav is in the layout (`application.html.erb`), the Stimulus controller will need to reach outside its element to hide it. Options:
- Use `document.querySelector` to find the aside
- Use Stimulus outlet to connect to a layout-level controller
- Add the controller at a higher level in the DOM

**Recommended:** Add `data-task-chat-target="sidebar"` to the aside in the layout, and scope the `task-chat` controller to a wrapper that includes both the aside and main content. Alternatively, use `this.element.closest` or direct DOM query since this is a page-level layout concern.

### Chat UI Styling

- Chat panel background: `var(--color-surface-container-low)` with subtle left border
- User messages: `var(--color-primary)` background, white text, right-aligned, rounded bubbles
- Assistant messages: `var(--color-surface-container-highest)` background, left-aligned, rounded bubbles
- Code blocks in assistant messages: monospace, darker background, with syntax highlighting if feasible
- Input: pill-shaped with circular send button using primary color
- Markdown rendering for assistant messages (bold, code, lists)

## Process Flow

### First Chat Open
1. User clicks "Chat with AI"
2. Frontend sends POST to create chat session
3. Backend spawns Claude with ticket context, gets initial greeting
4. Frontend transitions to side-by-side, shows greeting message

### Subsequent Messages
1. User types message, presses Enter or clicks send
2. Message immediately appears in chat (user bubble)
3. Frontend sends POST to message endpoint
4. Backend spawns `claude -p --resume` with the message
5. SSE stream delivers response tokens progressively
6. Assistant message bubble grows as tokens arrive
7. When stream completes, message is finalized

### Returning to Existing Chat
1. User navigates to task that has an active chat session
2. "Chat with AI" button shows indicator (e.g., dot or message count)
3. On click, existing messages loaded from DB and displayed
4. New messages resume the Claude session via `--resume`

## Testing

- Model tests: ChatSession and ChatMessage associations, validations, scoping
- Controller tests: create session, send message, authorization (workspace scoping)
- System tests: open chat, send message, close chat, expand/shrink transitions
- Mock the Claude CLI subprocess in tests to avoid actual API calls
