# Workshop Designs — Plan 2: Designs Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a project whose design repo is ready, a person opens Designs for a Workshop task, chats with Claude while a live preview of the task's working branch updates, switches contexts, and approves the work into `master`.

**Architecture:**
- **Chat.** A Designs chat is an ordinary `ChatSession` with the purpose `designs`, one per task, and its messages are `ChatMessage` rows. A new `kind` column marks summaries, new contexts, missing requirements and errors.
- **Turns.** Every message creates a `DesignTurn` and enqueues `Designs::TurnJob` on a dedicated `designs` queue. The job runs Claude in the task's `wip/<KEY>` worktree:
  - `--bare` on the project's own key, so the server's login is never used;
  - `--restricted`, with read and edit tools only;
  - the prompt appended from a file outside the worktree;
  - a cost cap and a timeout.

  Then Flosis — not Claude — commits through the Plan 1 `Committer`, pushes, and publishes the work-in-progress slot.
- **Live updates.** The screen polls a Turbo Frame while a turn is queued or running. There are no WebSockets: the Apache proxy on Hostido does not carry them.
- **Approval** is a service: it merges `wip/<KEY>` into `master`, points `design/<KEY>` at it, tags `approved/<KEY>/<n>` and publishes. On a conflict it offers "Update from master", which merges `master` into the working branch and, when files collide, runs a turn asking Claude to resolve the conflict markers.

**Tech Stack:** Rails 8.1, Minitest, Solid Queue, Turbo Frames, Stimulus (importmap, `pin_all_from "app/javascript/controllers"`), Claude CLI (`--bare`, `--restricted`, `--session-id`, `--resume`, `--append-system-prompt-file`, `--add-dir`, `--max-budget-usd`).

**Spec:** `docs/superpowers/specs/2026-10-30-workshop-designs-design.md`. **Builds on:** `docs/superpowers/plans/2026-10-30-workshop-designs-1-foundation.md` — before starting, check that its interfaces (`Designs::Repo`, `Committer`, `LeakGuard`, `Publisher`, `BranchNames`, `GitRunner`, `ClaudeCliService api_key:`) landed as written, and adjust names here if they did not.

## Global Constraints

- **Everything in Plan 1's Global Constraints still holds.** That covers MySQL-safe migrations, per-file test runs, no commit trailers, tokens never on disk, allowed paths, branch and tag names, and the preview URL scheme.
- **Queues.** Design turns run only on the `designs` queue. The existing worker gets an explicit `[default, mailers]` queue list, so design turns can never occupy it.
- **How Claude runs in a design turn:**
  - `--bare` with `ProjectCredentials#designs_api_key`, which is the project column only, with no environment fallback;
  - `--restricted`;
  - `--allowedTools Read Glob Grep Edit Write`;
  - `--append-system-prompt-file <file outside the worktree>`;
  - `--max-budget-usd ENV.fetch("DESIGNS_TURN_BUDGET_USD", "5")`;
  - a timeout of `ENV.fetch("DESIGNS_TURN_TIMEOUT_SECONDS", "900")` seconds.
- **The app checkout passed with `--add-dir` must be unchanged after a turn.** Any change there fails the turn and is reverted.
- **Claude's reply protocol:** exactly one `<summary>…</summary>` block, then any number of `<context>…</context>` and `<missing>…</missing>` blocks.
- **The per-task manifest** is `designs/tasks/<slug>.json`:
  `{"screens":[{"path":"designs/…/page.html","title":"…","contexts":["<value id>",…]}]}`.
- **The contexts file** (Plan 1) is `designs/contexts.json`:
  `{"dimensions":[{"id","name","values":[{"id","name"}],"default"}]}`.
- **UI copy is English** and uses the `clar-` classes. Every Designs page needs the `tasks` permission.

## Review Focus

1. **A deploy kills a running turn.** The turn must not stay "running" forever. A turn running longer than the timeout plus 5 minutes is failed with a Retry, and a re-delivered job takes it over.
   → Task 5 "a stale running turn is failed and can be retried".
2. **Claude edits the application checkout** it was only meant to read. The change is reverted and the turn fails.
   → Task 5 "a change to the app checkout is undone and fails the turn".
3. **Two people send messages to the same task at once.** The second turn waits, queued, and runs after the first.
   → Task 5 "turns of one task never run at the same time"; Task 7 "a second message while a turn runs is queued".
4. **Approve with nothing new** (`wip` equals `design`) is refused with a message, without an empty tag.
   → Task 6 "approving with nothing new is refused".
5. **A project without its own API key.** The composer is disabled with an explanation, and a POST is refused.
   → Task 7 "a project without its own API key cannot start a turn".

---

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `db/migrate/20261031100000_add_designs_sessions.rb` | `chat_messages.kind`, `design_turns`, `design_approvals` |
| `app/models/design_turn.rb` | A turn's lifecycle (queued → running → succeeded or failed); stale detection |
| `app/models/design_approval.rb` | One approval of a task: number, shas, who and when |
| `app/services/designs/prompt.rb` | The built-in system prompt (replaced by the Plan 3 library) and the per-turn message |
| `app/services/designs/turn_output.rb` | Parses Claude's tagged reply |
| `app/services/designs/working_branch.rb` | Reads a working tree: contexts, the manifest, the preview path |
| `app/services/designs/current_description.rb` | The description Claude designs from |
| `app/jobs/designs/turn_job.rb` | Runs one turn end to end |
| `app/services/designs/approval.rb` | Approve; update from `master` |
| `app/controllers/workshop/designs_controller.rb` | The Designs screen and its actions |
| `app/views/workshop/designs/show.html.erb`, `_top_bar.html.erb`, `_chat.html.erb`, `_message.html.erb`, `_preview.html.erb` | The screen |
| `app/javascript/controllers/designs_poll_controller.js` | Reloads the chat frame while a turn is active; tells the preview when a new commit lands |
| `app/javascript/controllers/designs_preview_controller.js` | The context picker; keeps the iframe and "Open in new tab" in step |

**Modified files**

- `app/models/chat_session.rb` — `PURPOSES` gains `designs`.
- `app/models/task.rb` — `has_many :design_approvals`.
- `app/services/project_credentials.rb` — `#designs_api_key`.
- `app/services/claude_cli_service.rb` — the design-turn options.
- `app/services/designs/repo.rb` — `#merge_master_into!`.
- `config/queue.yml`, `config/routes.rb`.
- `app/views/workshop/ideas/_workspace_header.html.erb` — the Designs entry.
- `app/views/workshop/configuration/_ai_tab.html.erb` — the API key field.

---

### Task 1: Turns, approvals and message kinds in the database

**Files:**
- Create: `db/migrate/20261031100000_add_designs_sessions.rb`, `app/models/design_turn.rb`, `app/models/design_approval.rb`
- Modify: `app/models/chat_session.rb`, `app/models/task.rb`, `app/services/project_credentials.rb`
- Test: `test/models/design_turn_test.rb`

**Interfaces:**
- Consumes: `ChatSession`, `ChatMessage`, `Task`.
- Produces:
  - **`chat_messages.kind`** (string, nullable). nil means an ordinary message; the other values are `summary`, `context`, `missing`, `error` and `system`.
  - **`design_turns`:**
    - `chat_session_id` (not null)
    - `chat_message_id` (not null; the user's message)
    - `status` (string, not null, default `"queued"`; one of `queued`, `running`, `succeeded`, `failed`)
    - `kind` (string, not null, default `"design"`; `design` or `resolve_conflicts`)
    - `error` (text), `commit_sha` (string), `started_at`, `finished_at`, timestamps
    - indexed on `[chat_session_id, status]`
  - **`design_approvals`:**
    - `task_id` (not null), `user_id` (not null)
    - `number` (integer, not null), unique on `[task_id, number]`
    - `design_sha`, `master_sha`, `tag` (strings, not null)
    - `created_at`
  - **`ChatSession`:** `PURPOSES = %w[refine breakdown brief designs]`; `has_many :design_turns, dependent: :destroy`.
  - **`DesignTurn`:**
    - `STATUSES`, `KINDS`, `ACTIVE = %w[queued running]`
    - `scope :active`
    - `#start!`, `#succeed!(commit_sha:)`, `#fail!(message)`
    - `.stale_after -> ActiveSupport::Duration` (the timeout plus 5 minutes)
    - `.fail_stale! -> Integer`, which fails running turns older than `stale_after` with `"Interrupted before it finished — retry it."`
    - `#stale? -> Boolean`
  - **`DesignApproval`** `belongs_to :task, :user`; **`Task`** `has_many :design_approvals, dependent: :destroy`.
  - **`ProjectCredentials#designs_api_key -> String | nil`** — `@project.anthropic_api_key.presence`, with no `ENV` fallback, and a comment citing the licensing rule.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/design_turn_test.rb
require "test_helper"

class DesignTurnTest < ActiveSupport::TestCase
  setup do
    task = tasks(:jira_task)
    @session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one),
                                   purpose: "designs", claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    @message = @session.chat_messages.create!(role: "user", content: "Add an archive tab", user: users(:one))
  end

  def turn(**attrs) = DesignTurn.create!({ chat_session: @session, chat_message: @message }.merge(attrs))

  test "a new turn is queued" do
    assert_equal "queued", turn.status
  end

  test "a turn moves through running to succeeded" do
    t = turn
    t.start!
    assert t.running?
    assert t.started_at
    t.succeed!(commit_sha: "abc123")
    assert t.succeeded?
    assert_equal "abc123", t.commit_sha
    assert t.finished_at
  end

  test "fail_stale! fails only running turns older than the timeout" do
    old = turn(status: "running", started_at: DesignTurn.stale_after.ago - 1.minute)
    fresh = turn(status: "running", started_at: 1.minute.ago)
    assert_equal 1, DesignTurn.fail_stale!
    assert old.reload.failed?
    assert_match(/Interrupted/, old.error)
    assert fresh.reload.running?
  end

  test "the designs api key never falls back to the server's key" do
    project = projects(:jira_project)
    project.update!(anthropic_api_key: nil)
    ENV["ANTHROPIC_API_KEY"] = "server-key"
    assert_nil ProjectCredentials.new(project).designs_api_key
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/design_turn_test.rb`
Expected: FAIL. The `designs` purpose is invalid and `DesignTurn` is undefined.

- [ ] **Step 3: Write the migration and the models**

- Every `create_table` and `add_column` is guarded (`table_exists?`, `column_exists?`).
- Use `t.references … foreign_key: true`.
- `DesignTurn` defines `queued?`, `running?`, `succeeded?` and `failed?` predicates.

- [ ] **Step 4: Migrate and run the test to verify it passes**

Run: `bin/rails db:migrate && bin/rails test test/models/design_turn_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261031100000_add_designs_sessions.rb db/schema.rb app/models/design_turn.rb app/models/design_approval.rb app/models/chat_session.rb app/models/task.rb app/services/project_credentials.rb test/models/design_turn_test.rb
git commit -m "feat: design turns, approvals and message kinds"
```

---

### Task 2: The CLI options a design turn needs

**Files:**
- Modify: `app/services/claude_cli_service.rb`
- Test: `test/services/claude_cli_service_test.rb`

**Interfaces:**
- Consumes: `api_key:` and `popen_args` (Plan 1, Task 4).
- Produces:
  - **New keyword options** on `ClaudeCliService.new`:
    - `restricted: false` → `--restricted`
    - `append_system_prompt_file: nil` → `--append-system-prompt-file <path>`
    - `add_dirs: []` → `--add-dir <dir>` once per directory
    - `max_budget_usd: nil` → `--max-budget-usd <value>`
    - `timeout: nil`, in seconds
  - **`#start_session(prompt:, new_session_id: nil)`** adds `--session-id <uuid>` when an id is given.
  - **`#resume_session(session_id:, prompt:) -> { session_id:, response: }`** is non-streaming and uses `--resume`.
  - **`ClaudeCliService::TimeoutError < ClaudeCliError`.** On timeout, `run_claude` sends TERM to the child (`io.pid`), then KILL after 5 seconds, and raises it.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "a design turn's command carries every guard rail" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, api_key: "k", restricted: true,
                                   append_system_prompt_file: "/tmp/p.md", add_dirs: [ "/srv/app" ],
                                   max_budget_usd: "5", allowed_tools: %w[Read Glob Grep Edit Write])
    cmd = service.send(:build_command, streaming: false)
    assert_includes cmd, "--restricted"
    assert_equal "/tmp/p.md", cmd[cmd.index("--append-system-prompt-file") + 1]
    assert_equal "/srv/app", cmd[cmd.index("--add-dir") + 1]
    assert_equal "5", cmd[cmd.index("--max-budget-usd") + 1]
    assert_equal %w[Read Glob Grep Edit Write], cmd.each_cons(2).select { |a, _| a == "--allowedTools" }.map(&:last)
  end

  test "a new session can be given its id up front" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    cmd = service.send(:build_command, streaming: false, new_session_id: "11111111-2222-3333-4444-555555555555")
    assert_equal "11111111-2222-3333-4444-555555555555", cmd[cmd.index("--session-id") + 1]
  end

  test "a run past its timeout is killed and raises" do
    service = ClaudeCliService.new(codebase_path: Dir.tmpdir, timeout: 0.3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(ClaudeCliService::TimeoutError) { service.send(:run_claude, [ "sleep", "10" ], "") }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 7
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/claude_cli_service_test.rb`
Expected: FAIL with `unknown keyword: :restricted`.

- [ ] **Step 3: Add the options, `resume_session`, the `new_session_id:` keyword of `build_command`, and the timeout in `run_claude`**

Wrap the read in `Timeout.timeout(@timeout)`, but only when a timeout is set. Existing callers pass none and behave exactly as before.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/claude_cli_service_test.rb`
Expected: PASS, the earlier tests included.

- [ ] **Step 5: Commit**

```bash
git add app/services/claude_cli_service.rb test/services/claude_cli_service_test.rb
git commit -m "feat: ClaudeCliService runs restricted, capped and timed, with a chosen session id"
```

---

### Task 3: What Claude is told, and what it answers

**Files:**
- Create: `app/services/designs/prompt.rb`, `app/services/designs/turn_output.rb`, `app/services/designs/current_description.rb`
- Test: `test/services/designs/prompt_test.rb`, `test/services/designs/turn_output_test.rb`, `test/services/designs/current_description_test.rb`

**Interfaces:**
- Consumes: `Task#current_detail_draft`, `Task#current_brief`, `Task#description`; `Designs::BranchNames.slug` (Plan 1).
- Produces:
  - **`Designs::Prompt::BASE`** — a frozen heredoc and the only system prompt until Plan 3. It must state:
    - the six allowed paths, and that nothing else is ever written;
    - reuse `components/` through `<x-include>` (Plan 1 syntax), and add a new component there before using it twice;
    - style only with `design_system/theme.css` tokens;
    - fake data beside the screens, varied by context;
    - contexts live in `designs/contexts.json` (format above) and are added only when the person asks;
    - keep `designs/tasks/<slug>.json` listing every screen this task touches, with the contexts that matter for each;
    - every page loads `runtime/flosis.js` by a relative path;
    - accessible markup (real buttons, links and labels);
    - the reply protocol, and that `<missing>` is for a requirement the person has not decided.
  - **`Designs::Prompt.system_text(project:) -> String`** — `BASE`, plus the project's name and `context_info`. Plan 3 replaces its body with the library composition.
  - **`Designs::Prompt.turn_message(task:, request:) -> String`** contains, in this order:
    1. `## Task` with `<slug> — <name>`;
    2. `## Current description` with `Designs::CurrentDescription.for(task)` or "(none yet)";
    3. `## Manifest path` with `designs/tasks/<slug>.json`;
    4. `## Request` with the person's text.
  - **`Designs::TurnOutput.parse(text) -> Designs::TurnOutput::Result`**, where `Result = Data.define(:summary, :contexts, :missing)`. Without a `<summary>`, `summary` is the first 300 characters of the stripped text.
  - **`Designs::CurrentDescription.for(task) -> String | nil`** — the current refine `TaskDraft`'s content, else the current `Brief`'s, else `task.description`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/designs/turn_output_test.rb
require "test_helper"

class Designs::TurnOutputTest < ActiveSupport::TestCase
  test "reads the summary, new contexts and missing requirements" do
    result = Designs::TurnOutput.parse(<<~TEXT)
      Done.
      <summary>Added the Archived tab and its empty state.</summary>
      <context>Plan: Free — archive hidden</context>
      <missing>What does a candidate see on an archived offer?</missing>
      <missing>Can an archived offer be restored?</missing>
    TEXT
    assert_equal "Added the Archived tab and its empty state.", result.summary
    assert_equal [ "Plan: Free — archive hidden" ], result.contexts
    assert_equal 2, result.missing.size
  end

  test "a reply without a summary block still yields a summary" do
    assert_equal "Just text", Designs::TurnOutput.parse("  Just text  ").summary
  end
end
```

```ruby
# test/services/designs/current_description_test.rb
require "test_helper"

class Designs::CurrentDescriptionTest < ActiveSupport::TestCase
  setup { @task = tasks(:jira_task) }

  test "the details draft wins over the brief and the description" do
    @task.update!(description: "from jira")
    @task.briefs.create!(workspace: @task.project.workspace, version: 1, content: "brief", origin: "ai").make_current!
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, content: "draft", origin: "ai").make_current!
    assert_equal "draft", Designs::CurrentDescription.for(@task)
  end

  test "the brief wins over the description" do
    @task.update!(description: "from jira")
    @task.briefs.create!(workspace: @task.project.workspace, version: 1, content: "brief", origin: "ai").make_current!
    assert_equal "brief", Designs::CurrentDescription.for(@task)
  end

  test "falls back to the task's description" do
    @task.update!(description: "from jira")
    assert_equal "from jira", Designs::CurrentDescription.for(@task)
  end
end
```

```ruby
# test/services/designs/prompt_test.rb
require "test_helper"

class Designs::PromptTest < ActiveSupport::TestCase
  test "the system prompt names the rules a turn must follow" do
    text = Designs::Prompt.system_text(project: projects(:jira_project))
    [ "design_system/", "components/", "designs/", "runtime/", "<x-include", "designs/contexts.json",
      "<summary>", "<missing>", "<context>", projects(:jira_project).name ].each { |fact| assert_includes text, fact }
  end

  test "every turn carries the task, its description, the manifest path and the request" do
    task = tasks(:jira_task)
    task.update!(external_reference: "REC-1", description: "Archive offers")
    message = Designs::Prompt.turn_message(task: task, request: "Add an archive tab")
    assert_match(/## Task\nREC-1 — #{Regexp.escape(task.name)}/, message)
    assert_includes message, "Archive offers"
    assert_includes message, "designs/tasks/REC-1.json"
    assert message.rstrip.end_with?("Add an archive tab")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run each file: `bin/rails test test/services/designs/turn_output_test.rb` (and the other two).
Expected: FAIL with `uninitialized constant`.

- [ ] **Step 3: Write the three services**

- [ ] **Step 4: Run the tests to verify they pass**

Run each file again.
Expected: PASS (7 runs).

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/prompt.rb app/services/designs/turn_output.rb app/services/designs/current_description.rb test/services/designs/prompt_test.rb test/services/designs/turn_output_test.rb test/services/designs/current_description_test.rb
git commit -m "feat: what a design turn tells Claude and how its reply is read"
```

---

### Task 4: Reading a working branch

**Files:**
- Create: `app/services/designs/working_branch.rb`
- Test: `test/services/designs/working_branch_test.rb`

**Interfaces:**
- Consumes: a directory, which is a worktree or the clone root.
- Produces:
  - `Designs::WorkingBranch.new(dir, slug)`
  - `#dimensions -> Array<Hash>`:
    - the parsed `designs/contexts.json` dimensions, each with string keys `id`, `name`, `values` and `default`;
    - `[]` when the file is missing or invalid;
    - dimensions without values are dropped.
  - `#default_ctx -> Array<String>` — per dimension, `default`, else the first value id.
  - `#screens -> Array<Hash>` — the manifest's screens (`path`, `title`, `contexts`), keeping only paths under `designs/` that exist in `dir`.
  - `#entry_path -> String` — the first screen's path, else `"index.html"`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/designs/working_branch_test.rb
require "test_helper"

class Designs::WorkingBranchTest < ActiveSupport::TestCase
  setup { @dir = Pathname(Dir.mktmpdir("wb")) }
  teardown { FileUtils.remove_entry(@dir) }

  def write(path, body)
    FileUtils.mkdir_p(@dir.join(path).dirname)
    File.write(@dir.join(path), body)
  end

  test "reads contexts and their defaults" do
    write("designs/contexts.json", { dimensions: [
      { id: "permissions", name: "Permissions", values: [ { id: "admin", name: "Admin" }, { id: "viewer", name: "Viewer" } ], default: "viewer" },
      { id: "plan", name: "Plan", values: [ { id: "pro", name: "Pro" } ] },
      { id: "empty", name: "Empty", values: [] }
    ] }.to_json)
    branch = Designs::WorkingBranch.new(@dir, "REC-1")
    assert_equal %w[permissions plan], branch.dimensions.map { _1["id"] }
    assert_equal %w[viewer pro], branch.default_ctx
  end

  test "a broken contexts file means no contexts" do
    write("designs/contexts.json", "{ nope")
    assert_empty Designs::WorkingBranch.new(@dir, "REC-1").dimensions
  end

  test "the entry page is the manifest's first existing screen" do
    write("designs/jobs/index.html", "<p>jobs</p>")
    write("designs/tasks/REC-1.json", { screens: [
      { path: "designs/gone.html", title: "Gone" },
      { path: "designs/jobs/index.html", title: "Jobs", contexts: [ "admin" ] },
      { path: "../secrets.html", title: "Escape" }
    ] }.to_json)
    branch = Designs::WorkingBranch.new(@dir, "REC-1")
    assert_equal [ "designs/jobs/index.html" ], branch.screens.map { _1["path"] }
    assert_equal "designs/jobs/index.html", branch.entry_path
  end

  test "without a manifest the entry page is the index" do
    assert_equal "index.html", Designs::WorkingBranch.new(@dir, "REC-1").entry_path
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/designs/working_branch_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write `Designs::WorkingBranch`**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/designs/working_branch_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/working_branch.rb test/services/designs/working_branch_test.rb
git commit -m "feat: read a design branch's contexts and the screens its task touches"
```

---

### Task 5: The turn runner

**Files:**
- Create: `app/jobs/designs/turn_job.rb`
- Modify: `config/queue.yml`
- Test: `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Consumes:
  - Tasks 1–4;
  - Plan 1: `Designs::Repo`, `#worktree!`, `#push!`, `#discard!`, `#synchronize`; `Designs::Committer`, `Designs::LeakGuard`; `Designs::Publisher#publish!`; `Designs::BranchNames`;
  - `Project#ai_codebase_path`.
- Produces:
  - `Designs::TurnJob.perform_later(turn_id)`, with `queue_as :designs` and `limits_concurrency to: 1, key: ->(turn_id) { DesignTurn.find(turn_id).chat_session.task_id }, duration: 2.hours`.
  - **Test seam:** the class attribute `Designs::TurnJob.claude_factory`, a lambda `->(**options) { ClaudeCliService-like }` that defaults to `ClaudeCliService.method(:new)`.
- **Behaviour, in order:**
  1. **Pick up the turn.** Only a `queued` turn, or a `stale?` `running` one, is taken; anything else returns. Call `start!`.
  2. **API key.** No `designs_api_key` → `fail!("This project has no Anthropic API key of its own. Add it in Configuration › AI.")`.
  3. **Worktree.** Inside `repo.synchronize`: `ensure_clone!`, then `worktree!(wip, from: <design/<slug> if that branch exists, else "master">)`.
  4. **Prompt file.** Write `Designs::Prompt.system_text` to a `Tempfile` under `Dir.tmpdir`, never inside the worktree.
  5. **Run Claude** through `claude_factory` with:
     - `codebase_path: worktree`
     - `allowed_tools: %w[Read Glob Grep Edit Write]`
     - `restricted: true`
     - `api_key:`
     - `append_system_prompt_file:`
     - `add_dirs: [project.ai_codebase_path].compact`
     - `max_budget_usd:` and `timeout:` from the environment

     The first turn of a session uses `start_session(prompt:, new_session_id: session.claude_session_id)`; later turns use `resume_session`. If a resume raises because the session is missing, start fresh with a new uuid and store it on the `ChatSession`.
  6. **App-checkout guard.** If `git status --porcelain` in the app checkout is non-empty: `checkout -- .` plus `clean -fd`, then `fail!("Claude changed the application's code, which it may only read. That change was undone.")`.
  7. **Commit.** `TurnOutput.parse`, then, inside `repo.synchronize`, `Committer#commit!(worktree, message: "#{slug}: #{summary first line, at most 72 characters}")`.
     - The guard's `forbidden_texts:` is `[Designs::Prompt::BASE]`.
     - Its `secrets:` are every credential on the project.
     - A refusal → `fail!("Refused: <path> <reason>")`.
  8. **Publish.** When there is a sha: `push!(wip)` and `publish!(wip, "wip/<slug>")`.
  9. **Messages.** Assistant `ChatMessage`s: one `summary`, one per `context`, one per `missing`.
  10. **Finish.** `succeed!(commit_sha:)`.
  11. **On any error:** `repo.discard!(worktree)` when it exists, `fail!(message)`, and an assistant message of kind `error` with that text. Errors are never re-raised; the turn records them.
- **`config/queue.yml`.** The `default` and `production` workers become `queues: [default, mailers]` with `threads: 3`, plus a second worker `queues: [designs]` with `threads: 2`. Development gets the same split.

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/designs/turn_job_test.rb
require "test_helper"

class Designs::TurnJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
    Designs::TurnJob.claude_factory = nil
  end

  # A stand-in for Claude: edits the worktree, then answers.
  def fake_claude(files: {}, reply: "<summary>Did it.</summary>", raise_error: nil, app_dir_write: nil)
    Designs::TurnJob.claude_factory = lambda do |**opts|
      Object.new.tap do |cli|
        run = lambda do |**|
          raise raise_error if raise_error
          files.each { |p, b| FileUtils.mkdir_p(File.dirname(File.join(opts[:codebase_path], p))); File.write(File.join(opts[:codebase_path], p), b) }
          File.write(File.join(app_dir_write, "hacked.rb"), "x") if app_dir_write
          { session_id: "s", response: reply }
        end
        cli.define_singleton_method(:start_session) { |**kw| run.call(**kw) }
        cli.define_singleton_method(:resume_session) { |**kw| run.call(**kw) }
      end
    end
  end

  def new_turn(task)
    session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                                  claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    msg = session.chat_messages.create!(role: "user", content: "Add an archive tab", user: users(:one))
    DesignTurn.create!(chat_session: session, chat_message: msg)
  end

  test "a turn commits Claude's work to the working branch, pushes it and publishes it" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { "designs/jobs.html" => "<p>jobs</p>" },
                  reply: "<summary>Added jobs.</summary><missing>Who can archive?</missing>")
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      turn.reload
      assert turn.succeeded?, turn.error
      assert_equal turn.commit_sha, remote_branch_sha(remote, "wip/REC-1")
      assert File.exist?(File.join(@preview_root, repo.project.design_preview_token, "wip", "REC-1", "designs", "jobs.html"))
      assert_equal %w[summary missing], turn.chat_session.chat_messages.where(role: "assistant").ordered.pluck(:kind)
    end
  end

  test "a refused change fails the turn and leaves the branch where it was" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { ".claude/skill.md" => "x" })
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.failed?
      assert_match(/Refused: \.claude\/skill\.md/, turn.error)
      assert_nil remote_branch_sha(remote, "wip/REC-1")
    end
  end

  test "a change to the app checkout is undone and fails the turn" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      # Not checkout!(project): that moves workspace_dir, and the design repo lives there too.
      repo.project.update!(github_repo: "acme/app")
      app = repo.project.repo_checkout_path
      FileUtils.mkdir_p(app)
      system("git", "-C", app, "init", "-q", exception: true)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(app_dir_write: app)
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.failed?
      assert_not File.exist?(File.join(app, "hacked.rb"))
    end
  end

  test "a project without its own API key fails the turn with the way out" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: nil)
      task = tasks(:jira_task)
      task.update!(project: repo.project)
      fake_claude
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert_match(/Configuration › AI/, turn.reload.error)
    end
  end

  test "a stale running turn is failed and can be retried" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      turn = new_turn(task)
      turn.update!(status: "running", started_at: DesignTurn.stale_after.ago - 1.minute)
      fake_claude(files: { "designs/a.html" => "a" })
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.succeeded?, "a re-delivered job takes over a stale turn"
    end
  end

  test "turns of one task never run at the same time" do
    assert_equal 1, Designs::TurnJob.concurrency_limit
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: FAIL with `uninitialized constant Designs::TurnJob`.

- [ ] **Step 3: Write the job and change `config/queue.yml`**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: PASS (6 runs).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/designs/turn_job.rb config/queue.yml test/jobs/designs/turn_job_test.rb
git commit -m "feat: a design turn runs Claude on the task's branch, then Flosis commits, pushes and publishes"
```

---

### Task 6: Approval, and bringing a branch up to date with master

**Files:**
- Create: `app/services/designs/approval.rb`
- Modify: `app/services/designs/repo.rb` (`#merge_master_into!`)
- Test: `test/services/designs/approval_test.rb`, `test/services/designs/repo_test.rb`

**Interfaces:**
- Consumes: Plan 1's `Repo`, `Publisher` and `BranchNames`; Task 1's `DesignApproval`, `DesignTurn`, `ChatMessage` kinds; Task 5's `TurnJob`.
- Produces:
  - **`Designs::Repo#merge_master_into!(dir) -> Array<String>`:**
    - It runs `git merge master` with the Flosis identity inside the worktree.
    - It returns `[]` after a clean merge commit.
    - On conflict it returns the conflicted paths and leaves the merge in progress, with the markers in the files.
  - **`Designs::Approval.new(task, user:)`**
  - **`#approve! -> DesignApproval`**, all inside `repo.synchronize`:
    1. `ensure_clone!`;
    2. `wip_sha = head(wip)`; raise `Designs::Approval::NothingToApprove` when `wip_sha` is nil or equals `head(design)`;
    3. `merge_into_master!(wip, message: "Approve <slug>")` — `Designs::Repo::Conflict` propagates;
    4. `point!(design, to: wip_sha)`;
    5. `n = tags("approved/<slug>/*").size + 1`, then `tag!(approval_tag(slug, n), at: master_sha)`;
    6. `push!(design, "master", tag)`;
    7. `publish!(design, slug)` and `publish!("master", "master")`;
    8. create the `DesignApproval`;
    9. add a `system` chat message: `"Approved as version <n>."`
  - **`#update_from_master! -> :merged | :resolving`.** It merges `master` into the `wip` worktree.
    - A clean merge is pushed and published, and returns `:merged`.
    - Conflicts create a `system` message naming the files, plus a `DesignTurn` of kind `resolve_conflicts`. Its user message is `"Resolve the merge conflict markers in: <paths>. Keep this task's intent and master's newer changes."`. `TurnJob` is enqueued and `:resolving` is returned.
    - The `TurnJob` commit then completes the merge, because `git commit` in a worktree with a merge in progress records the merge.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/designs/approval_test.rb
require "test_helper"

class Designs::ApprovalTest < ActiveSupport::TestCase
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  def task_on(repo)
    tasks(:jira_task).tap { _1.update!(project: repo.project, external_reference: "REC-1") }
  end

  def session_for(task)
    ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                        claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
  end

  test "approving merges the work into master, moves the design branch, tags and publishes" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      approval = with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      assert_equal 1, approval.number
      assert_equal "approved/REC-1/1", approval.tag
      assert_equal wip, remote_branch_sha(remote, "design/REC-1")
      assert_equal approval.master_sha, remote_branch_sha(remote, "master")
      token = repo.project.reload.design_preview_token
      assert File.exist?(File.join(@preview_root, token, "REC-1", "designs", "jobs.html"))
      assert File.exist?(File.join(@preview_root, token, "master", "designs", "jobs.html"))
    end
  end

  test "approving with nothing new is refused" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/jobs.html" => "jobs" })
      with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      assert_raises(Designs::Approval::NothingToApprove) do
        with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      end
      assert_equal 1, task.design_approvals.count
    end
  end

  test "a second approval is version 2" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = task_on(repo)
      session_for(task)
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/a.html" => "1" })
      with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      commit_files(repo, dir, { "designs/a.html" => "2" })
      second = with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).approve! }
      assert_equal "approved/REC-1/2", second.tag
    end
  end

  test "updating from master with colliding files starts a resolving turn" do
    with_design_remote do |repo, remote|
      seed_master(repo, { "designs/a.html" => "base\n" })
      task = task_on(repo)
      session_for(task)
      commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n" })
      repo.push!("master")
      outcome = assert_enqueued_with(job: Designs::TurnJob) do
        with_remote_url(remote) { Designs::Approval.new(task, user: users(:one)).update_from_master! }
      end
      assert_equal :resolving, outcome
      assert_equal "resolve_conflicts", DesignTurn.last.kind
      assert_includes DesignTurn.last.chat_message.content, "designs/a.html"
    end
  end
end
```

In `test/services/designs/repo_test.rb` add:

```ruby
  test "merge_master_into! makes a merge commit when nothing collides" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/a.html" => "a\n" })
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/b.html" => "b\n" })
      commit_files(repo, repo.root, { "designs/c.html" => "c\n" })
      assert_equal [], repo.merge_master_into!(dir)
      assert dir.join("designs/c.html").exist?
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/designs/approval_test.rb && bin/rails test test/services/designs/repo_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write `merge_master_into!` and `Designs::Approval`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/designs/approval_test.rb && bin/rails test test/services/designs/repo_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/approval.rb app/services/designs/repo.rb test/services/designs/approval_test.rb test/services/designs/repo_test.rb
git commit -m "feat: approve a task's designs into master, and bring a branch up to date with master"
```

---

### Task 7: The Designs screen

**Files:**
- Create:
  - `app/controllers/workshop/designs_controller.rb`
  - `app/views/workshop/designs/show.html.erb`, `_top_bar.html.erb`, `_chat.html.erb`, `_message.html.erb`, `_preview.html.erb`
  - `app/javascript/controllers/designs_poll_controller.js`, `app/javascript/controllers/designs_preview_controller.js`
- Modify: `config/routes.rb`, `app/views/workshop/ideas/_workspace_header.html.erb`
- Test: `test/controllers/workshop/designs_controller_test.rb`

**Interfaces:**
- Consumes: Tasks 1–6; `Designs::Publisher#url`; `Designs::Repo#commits_ahead`, `#head`.
- Produces:
  - **Routes**, inside the `resources :ideas` block:

    ```ruby
    resource :designs, only: :show, controller: "designs" do
      get :chat
      post :message
      post :approve
      post :update_from_master
      post :retry
    end
    ```

    The helpers are `workshop_idea_designs_path(idea)`, `chat_workshop_idea_designs_path`, `message_workshop_idea_designs_path`, `approve_workshop_idea_designs_path`, `update_from_master_workshop_idea_designs_path` and `retry_workshop_idea_designs_path`.
  - **`Workshop::DesignsController < Workshop::BaseController`:**
    - `before_action { require_permission!(:tasks) }`.
    - The idea is `current_workshop_project.tasks.pipeline.find(params[:idea_id])`.
    - When the project's Designs is off, or `design_repo_status` isn't `"ready"`, it redirects to the idea with the alert `"Designs isn't set up for this project — see Configuration › Designs."`.
    - **`show`** and **`chat`** call `DesignTurn.fail_stale!` first. `chat` renders only the `designs-chat` frame.
    - **`message`**:
      - finds or creates the `designs` `ChatSession` (`claude_session_id: SecureRandom.uuid`, `codebase_path` = the worktree path);
      - refuses with `422` and an `error` message when the project has no `designs_api_key`;
      - creates the user `ChatMessage` and a queued `DesignTurn`, and enqueues `Designs::TurnJob`;
      - responds with the chat frame.
    - **`approve`** calls `Approval#approve!` and redirects back with the toast `"Approved as version <n>."`.
      - `NothingToApprove` → alert `"Nothing new to approve."`.
      - `Conflict` → alert `"Master has changed in the same files. Use “Update from master”, then approve again."`, and the top bar shows that button.
    - **`update_from_master`** calls `Approval#update_from_master!`.
    - **`retry`** resets the latest failed turn to `queued` and re-enqueues it.
- **Screen**, full-bleed like the idea page:
  - **Top bar** (approved mockup):
    - breadcrumb `Workshop › <KEY> <name> › Designs`;
    - pill `design/<slug> · <n> waiting`, where n is `commits_ahead(wip, base: design if it exists, else "master")`;
    - "Open in new tab ↗" linking `Publisher#url("wip/<slug>", entry_path, ctx: default_ctx)`;
    - "Approve → master", disabled when n is 0 or a turn is active.
  - **Left:** `turbo_frame_tag "designs-chat"` with the messages and the composer. The frame root carries `data-designs-poll-active-value` (whether any turn is queued or running) and `data-designs-poll-commit-value` (the latest succeeded `commit_sha`).
    - Message styles by kind: user right; `summary` plain; `context` with an accent border and the label "New context"; `missing` with a warn border and the label "Missing requirement"; `error` with a danger border and a "Retry" button; `system` muted.
  - **Right:**
    - one row of pills per dimension, from `WorkingBranch#dimensions` read from the worktree (or the clone root before the first turn);
    - a "+ Context — ask in the chat" pill, which focuses the composer with `"Add a context: "`;
    - an `<iframe>` of the work-in-progress URL (`master` before the first commit).
- **`designs_preview_controller.js`.** Clicking a pill makes it the active value of its dimension and rebuilds the `?ctx=` of both the iframe `src` and the "Open in new tab" `href`. On the `designs:commit` window event it reloads the iframe.
- **`designs_poll_controller.js`.** While `active` is true it reloads the frame every 2 seconds, reusing the `clar_document_refresh_controller.js` technique of removing `complete` and setting `src`. When the `commit` value changes it dispatches `designs:commit` on `window`.
- **Header entry.** In `_workspace_header.html.erb`, next to the stepper: `link_to "Designs", workshop_idea_designs_path(idea), class: "clar-btn"`, only when the project's Designs is on and `design_repo_status == "ready"`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/designs_controller_test.rb
require "test_helper"

class Workshop::DesignsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "ready", design_preview_token: "t0k", anthropic_api_key: "sk-ant")
    @idea = tasks(:jira_task)
    @idea.update!(project: @project, external_reference: "REC-1")
    @idea.enter_pipeline!(author: users(:one), stage: "briefing")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "the screen shows the approved top bar, the chat frame and the preview" do
    get workshop_idea_designs_path(@idea)
    assert_response :success
    assert_select "body", /Designs/
    assert_select "body", %r{design/REC-1}
    assert_select "a", /Open in new tab/
    assert_select "button, input[type=submit]", /Approve/
    assert_select "turbo-frame#designs-chat"
    assert_select "iframe[src^=?]", "#{Designs::Publisher.base_url}/t0k/"
  end

  test "a message starts a queued turn" do
    assert_enqueued_with(job: Designs::TurnJob) do
      post message_workshop_idea_designs_path(@idea), params: { content: "Add an archive tab" }
    end
    turn = DesignTurn.last
    assert turn.queued?
    assert_equal "Add an archive tab", turn.chat_message.content
    assert_equal "designs", turn.chat_session.purpose
  end

  test "a second message while a turn runs is queued" do
    post message_workshop_idea_designs_path(@idea), params: { content: "first" }
    DesignTurn.last.start!
    post message_workshop_idea_designs_path(@idea), params: { content: "second" }
    assert_equal %w[running queued], DesignTurn.order(:id).pluck(:status)
  end

  test "a project without its own API key cannot start a turn" do
    @project.update!(anthropic_api_key: nil)
    get workshop_idea_designs_path(@idea)
    assert_select "body", /Configuration › AI/
    assert_no_enqueued_jobs(only: Designs::TurnJob) do
      post message_workshop_idea_designs_path(@idea), params: { content: "hi" }
    end
    assert_response :unprocessable_entity
  end

  test "Designs that are not set up send you back to the idea" do
    @project.update!(design_repo_status: nil)
    get workshop_idea_designs_path(@idea)
    assert_redirected_to workshop_idea_path(@idea)
  end

  test "someone without the Tasks permission is kept out" do
    project_memberships(:two_elvium).update!(PermissionPreset::PERMISSIONS.index_with(false).merge(briefing_config: true))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    get workshop_idea_designs_path(@idea)
    assert_response :redirect
  end

  test "the idea header links to Designs only when they are ready" do
    get workshop_idea_path(@idea)
    assert_select "a[href=?]", workshop_idea_designs_path(@idea)
    @project.update!(designs_enabled: false)
    get workshop_idea_path(@idea)
    assert_select "a[href=?]", workshop_idea_designs_path(@idea), count: 0
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/designs_controller_test.rb`
Expected: FAIL with a routing error.

- [ ] **Step 3: Write the routes, the controller, the views, the two Stimulus controllers and the header entry**

Keep the view work in partials: one each for the top bar, the chat, a message and the preview.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/workshop/designs_controller_test.rb`
Expected: PASS (7 runs).

- [ ] **Step 5: Verify in the browser**

1. Set up local Designs for one project as in Plan 1, Task 12, Step 2.
2. Run `bin/designs-preview`.
3. Open a task's Designs, using the Playwright MCP tools.

Expected:
- the top bar matches the approved mockup (`.superpowers/brainstorm/52989-1793381523/content/designs-screen-v2.html`);
- clicking a context pill changes the iframe's `?ctx=`;
- a sent message shows "working…", and the frame refreshes until the turn ends. The turn fails with the API-key message if `sk-ant` is fake, which is the expected local outcome.

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/workshop/designs_controller.rb app/views/workshop/designs app/javascript/controllers/designs_poll_controller.js app/javascript/controllers/designs_preview_controller.js app/views/workshop/ideas/_workspace_header.html.erb test/controllers/workshop/designs_controller_test.rb
git commit -m "feat: the Designs screen — chat beside a live preview, contexts, approve to master"
```

---

### Task 8: The project's own Anthropic API key in Configuration › AI

**Files:**
- Modify: `app/views/workshop/configuration/_ai_tab.html.erb`
- Test: `test/controllers/workshop/configuration_controller_test.rb`

**Interfaces:**
- Consumes: `AI_FIELDS` and `SECRETS` already include `anthropic_api_key`, so only the field is missing.
- Produces: a write-only `project[anthropic_api_key]` password field in the AI tab, in the GitHub token's pattern (masked placeholder with the last 4 characters, "Leave blank to keep the current key."). Its hint: "Designs runs only on this key. Claude is billed to it, not to Flosis."

- [ ] **Step 1: Write the failing test**

```ruby
  test "the AI tab takes the project's own Anthropic key, and a blank field keeps it" do
    get workshop_configuration_path(tab: "ai")
    assert_select "input[type=password][name='project[anthropic_api_key]']"
    @project.update!(anthropic_api_key: "sk-ant-keep")
    patch workshop_configuration_path, params: { tab: "ai", project: { anthropic_api_key: "" } }
    assert_equal "sk-ant-keep", @project.reload.anthropic_api_key
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: FAIL. There is no such input.

- [ ] **Step 3: Add the field**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/views/workshop/configuration/_ai_tab.html.erb test/controllers/workshop/configuration_controller_test.rb
git commit -m "feat: a project can carry its own Anthropic API key"
```

---

### Task 9: Production — stop and ask Kacper before each outward step

- [ ] **Step 1: Check the server's Claude CLI.**
  `ssh` as in the server runner reference, then `claude --version` and `claude --help | grep -E -- "--restricted|--max-budget-usd|--append-system-prompt-file|--session-id|--bare"` must list all five.
  If any is missing, updating the CLI changes every AI job's default model, so ask Kacper first.
- [ ] **Step 2: Agree the per-turn cost cap with Kacper.** The default is `DESIGNS_TURN_BUDGET_USD=5`. Add it and `DESIGNS_TURN_TIMEOUT_SECONDS=900` to `.env.production`, then run `cap production setup:upload_env`.
- [ ] **Step 3: Deploy.** `git push`, then `cap production deploy`, right after a 5-minute automation tick with nothing claimed. Afterwards, confirm that Solid Queue runs two workers: `bin/jobs` lists the `designs` queue.
- [ ] **Step 4: End to end on Gold, the pilot.**
  1. Put the company key in Gold's project (Configuration › AI).
  2. Open a task, then Designs. Ask for a small screen.
  3. The preview shows it, and a context pill switches it.
  4. Approve. The `design/<KEY>` link opens the approved version, and `master` contains it.
