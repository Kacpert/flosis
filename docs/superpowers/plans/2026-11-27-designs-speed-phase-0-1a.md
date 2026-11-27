# Designs speed, Phases 0 and 1a — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify what the server's CLI can do for executors (Phase 0). Then ship
the cheap half of the speed-up (Phase 1a):
- a new Claude session when the old one has gone cold or grown;
- design turns at medium effort;
- `theme.css` no longer pasted into the map;
- editing rules that cut steps.

Measure the result on B1 and B2.

**Architecture:**
- `Designs::SessionChoice` decides, per turn, whether to start, resume or
  renew the thread's Claude session. It reads the previous turn's finish
  time and the context size, which `Designs::TurnActivity` now records from
  the stream.
- `Designs::TurnJob` follows that choice.
- A turn that starts a new session gets the thread's conversation
  (`Designs::ThreadHistory`) and the branch's changed paths in its message.
- Prompt and map changes are text-only.
- A rails-runner harness (`script/designs_benchmark.rb`) replays B1 and B2 on
  the server with the same subject, prompts and CLI flags as a real turn.

**Tech Stack:** Rails 8.1, Minitest, PostgreSQL in tests and MariaDB in
production, Claude CLI 2.1.328 on the server (stream-json).

**Spec:** `docs/superpowers/specs/2026-11-27-designs-turns-five-times-faster-design.md`
(sections 1, 3 and 7, and "Verify first").

## Global Constraints

- **Server CLI:** it stays at 2.1.328 and is never updated. Every probe
  command runs with `DISABLE_AUTOUPDATER=1`.
- **Keyed turns** (own API key, `--bare`) are unchanged in 1a.
- **Session thresholds:** a session is warm while its last turn finished less
  than **55 minutes** ago, and small while its last context is under
  **150_000** tokens. A context of unknown size counts as large.
- **Thread history** in a new session's message is at most **20_000**
  characters, and the oldest messages go first when it is cut.
- **Effort:** `DesignTurn::DESIGN_EFFORT = "medium"`, for a thread's design,
  components and resolving turns. Setup and task-chat turns keep no effort.
- **Unchanged:**
  - The leak guard's four folders.
  - `Designs::Includes`.
  - The runtime, and `lib/designs_crawler/*.mjs`, so nothing needs
    uploading.
  - The plan and proposal flow: a thread's first message is planned, and
    later messages may propose.
- **Migrations:** plain `add_column`. SQL must be portable (MariaDB in
  production).
- **Tests:** one file at a time, with
  `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_designs_speed bin/rails test <file>`
  (create the DB first with `RAILS_ENV=test DATABASE_URL=postgres://localhost/gold_test_designs_speed bin/rails db:create db:schema:load`).
  A run that prints no "N runs" line did not run: run it again.
- **Commits:**
  - in English;
  - with explicit `git add` paths;
  - with no Claude co-author or session trailer.
- **Deploys:**
  - only when `SolidQueue::ClaimedExecution` is empty and
    `DesignTurn.where(status: %w[queued running])` is 0, right after a
    5-minute tick;
  - push origin and kacper before `cap production deploy`;
  - run `bin/rails tailwindcss:build` in the worktree first;
  - check `/up`;
  - mirror main.

## Review Focus

1. **Threads from before the deploy have no recorded context size.** Their
   next message must renew the session, not resume a 385k one. Pinned in
   Task 3: "a session whose size is unknown is renewed".
2. **An on-screen check between a build and the next message** runs in a
   session of its own, so it must not count as the thread's last turn. Pinned
   in Task 3.
3. **"Try again" on a build that answered a plan** must still resume the
   plan's session. Pinned in Task 3.
4. **The thread history** must not repeat the message being answered, nor
   carry Flosis's hidden requests (`kind: "request"`) or system notes. Pinned
   in Task 4.
5. **A branch with no changes of its own, or a git error,** must produce no
   empty "Changed on this branch" heading and must never fail the turn.
   Pinned in Task 4.

---

### Task 1: Phase 0 — probe the server's CLI

**Files:**
- Create (scratchpad, not the repo): `probe_agents.sh`
- Modify: `docs/superpowers/specs/2026-11-27-designs-turns-five-times-faster-design.md` (append "Phase 0 results")

**Interfaces:**
- Produces: the answers to "Verify first" items 1–7, which Phase 1b's plan
  consumes.

- [ ] **Step 1: Write `probe_agents.sh`**

  It runs on the server in one SSH session (`bash -l -s`), in a fresh
  `~/tmp/designs-speed-probe` holding `a.html` (`<title>Old</title>`) and
  `b.html` (`foo foo`). Every run has `DISABLE_AUTOUPDATER=1` and
  `--output-format stream-json --verbose`, and its stream is saved to its own
  file.
  - **(a) Tools.** `~/.local/bin/claude -p --restricted "Say ok"`. Print the
    init event's `tools` and `agents`, which give the subagent tool's real
    name (Agent or Task).
  - **(b) Agents.** Use `--restricted --tools Read Glob Grep Edit Write <subagent tool>`,
    `--allowedTools` with the same names, `--effort medium` and
    `--max-budget-usd 1`. Pass `--agents` with two definitions:
    - `designs-builder`: model `claude-sonnet-5-5`, tools
      Read/Edit/Write/Grep/Glob;
    - `designs-editor`: model `claude-haiku-5-5`, tools Read/Edit only.

    The prompt asks the lead to send both agents in **one** message:
    - the builder sets a.html's title to "Builder";
    - the editor replaces every "foo" in b.html with "bar", and then tries to
      create c.html (which it should not be able to do).

    The lead makes no edits itself.
  - **(c) Cost cap.** The same as (b), with `--max-budget-usd 0.02`.
  - **(d) Bare mode.** `ANTHROPIC_API_KEY=sk-ant-probe-invalid ~/.local/bin/claude -p --bare --tools Read Glob Grep Edit Write <subagent tool> "Say ok"`.
  - **(e) Empty config dir.**
    `CLAUDE_CONFIG_DIR=$(mktemp -d) ANTHROPIC_API_KEY=sk-ant-probe-invalid ~/.local/bin/claude -p --restricted --tools Read Glob Grep Edit Write <subagent tool> "Say ok"`.
  - **Analysis,** with `rbenv exec ruby -rjson`, for each run:
    - the init event's `tools`, `agents`, `apiKeySource` and `model`;
    - the count of events with a non-null `parent_tool_use_id`;
    - the result event's `subtype`, `is_error`, `total_cost_usd` and
      `modelUsage` keys;
    - for (b), each subagent transcript under
      `~/.claude/projects/*designs-speed-probe*/<session>/subagents/`, with
      its `model` and its first and last timestamps;
    - the final a.html, b.html and whether c.html exists.
  - **Cleanup:** remove `~/tmp/designs-speed-probe` and
    `~/.claude/projects/*designs-speed-probe*`.

- [ ] **Step 2: Run it**

  Run: `ssh -o BatchMode=yes -p 64321 host420646@host420646.hostido.net.pl 'bash -l -s' < probe_agents.sh`

  Expected: one report that answers items 1–7. For each item it says yes,
  no or unknown, with the evidence line.

- [ ] **Step 3: Record the results and commit**

  Append "## Phase 0 results (2026-11-27)" to the spec:
  - one line per item, with the evidence;
  - any fall-back the spec's "If an answer is no" list now applies.

  ```bash
  git add docs/superpowers/specs/2026-11-27-designs-turns-five-times-faster-design.md
  git commit -m "docs: Phase 0 results for the Designs speed design"
  ```

### Task 2: A turn keeps the largest context its own requests had

**Files:**
- Create: `db/migrate/20261127100000_add_context_tokens_to_design_turns.rb`
- Modify: `db/schema.rb` (by the migration), `app/services/designs/turn_activity.rb`
- Test: `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Produces:
  - `design_turns.context_tokens`, an integer or null;
  - `Designs::TurnActivity#context_tokens` (Integer or nil), saved with the
    steps.

- [ ] **Step 1: Write the failing test** (in turn_job_test, beside the
  streaming tests)

  ```ruby
  test "a turn keeps the largest context its own requests had, not a subagent's" do
    with_design_remote do |repo, remote|
      base = plan_seed(repo)
      used = ->(input, read, write, parent = nil) {
        { "type" => "assistant", "parent_tool_use_id" => parent,
          "message" => { "id" => "m-#{SecureRandom.hex(3)}", "content" => [],
                         "usage" => { "input_tokens" => input, "cache_read_input_tokens" => read, "cache_creation_input_tokens" => write } } }
      }
      streaming_claude(events: ->(_opts) { [ used.(10, 30_000, 5_000), used.(5, 900_000, 0, "agent-1"), used.(2, 41_000, 1_000) ] })

      turn = run_turn(thread_turn(repo, base), remote)

      assert_equal 42_002, turn.context_tokens
    end
  end
  ```

- [ ] **Step 2: Run it**

  Run: `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_designs_speed bin/rails test test/jobs/designs/turn_job_test.rb -n "/largest context/"`

  Expected: an ERROR naming the missing `context_tokens` attribute.

- [ ] **Step 3: Implement**
  - **Migration:** `add_column :design_turns, :context_tokens, :integer`.
    Run `bin/rails db:migrate`, and the test-DB schema load.
  - **`TurnActivity`:**
    - it starts from `turn.context_tokens`;
    - for each top-level assistant event (after the existing guard), it
      keeps the maximum of `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
      from `message.usage`;
    - `save` writes `context_tokens` in the same `update_columns` as
      `activity`.

- [ ] **Step 4: Run the test file**

  Run: `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_designs_speed bin/rails test test/jobs/designs/turn_job_test.rb`

  Expected: PASS, every test.

- [ ] **Step 5: Commit**

  ```bash
  git add db/migrate/20261127100000_add_context_tokens_to_design_turns.rb db/schema.rb app/services/designs/turn_activity.rb test/jobs/designs/turn_job_test.rb
  git commit -m "feat: a design turn keeps the largest context its own requests had"
  ```

### Task 3: Which session a turn runs in

**Files:**
- Create: `app/services/designs/session_choice.rb`
- Modify: `app/models/design_turn.rb`, `app/services/designs/subject.rb`
- Test: `test/services/designs/session_choice_test.rb`

**Interfaces:**
- Consumes: `DesignTurn#context_tokens` (Task 2).
- Produces:
  - `DesignTurn#answers_plan? → Boolean`. This is the rule
    `ThreadSubject#after_plan?` has today, moved onto the model; `after_plan?`
    now calls it.
  - `Designs::SessionChoice.for(turn, renews:, now: Time.current) → :start | :resume | :renew`.
    Its constants are `WARM_FOR = 55.minutes`, `SMALL_BELOW = 150_000` and
    `ALWAYS_NEW = %w[resolve_conflicts components]`.
  - `#renews_sessions?` on every subject: ThreadSubject true, TaskSubject
    false, SetupSubject false.
- **The rules, in this order:**
  1. **:start** when no other turn of the chat session (not a check) has
     started.
  2. **:resume** unless `renews`.
  3. **:renew** for `ALWAYS_NEW` kinds.
  4. **:resume** when `turn.answers_plan?`.
  5. **:resume** when the last such turn finished less than `WARM_FOR`
     before `now` and its `context_tokens` is under `SMALL_BELOW`.
  6. **:renew** otherwise.

- [ ] **Step 1: Write the failing tests**

  Build the thread as `subject_test`'s `thread_with_turn` does. Add turns
  with the given `kind`, `status`, `started_at`, `finished_at`,
  `context_tokens` and their own chat messages. Pass `now:` explicitly.
  - `"a chat's first turn starts its session"`: the only turn gives `:start`.
  - `"a build that answers a plan resumes the plan's session, however old or large"`:
    - a plan that succeeded, finished 3 hours ago, context 400_000;
    - then a design on a new message.

    Expect `:resume`.
  - `"a later message resumes a session that is warm and small"`: the last
    design finished 10 minutes ago, context 149_999. Expect `:resume`.
  - `"a later message renews a session gone cold"`:
    - finished 56 minutes ago, context 10_000 → `:renew`;
    - finished 54 minutes ago → `:resume`.
  - `"a later message renews a session past 150k tokens"`: context 150_000,
    finished 1 minute ago → `:renew`.
  - `"a session whose size is unknown is renewed"`: context nil, finished 1
    minute ago → `:renew`.
  - `"components and resolving turns always renew"`: behind a warm, small
    turn, both kinds give `:renew`.
  - `"a check does not count as the session's last turn"`:
    - a design finished 10 minutes ago, context 10_000;
    - then a check finished 1 minute ago, context nil.

    Expect `:resume`.
  - `"Try again on a build that answered a plan still resumes the plan's session"`:
    - a plan that succeeded on m1;
    - a failed design (started) on m2;
    - a new design on m2.

    Expect `:resume`.
  - `"a subject that does not renew resumes as before"`: `renews: false` and
    a cold, large last turn → `:resume`.

- [ ] **Step 2: Run them**

  Run: `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_designs_speed bin/rails test test/services/designs/session_choice_test.rb`

  Expected: ERROR, uninitialized constant `Designs::SessionChoice`.

- [ ] **Step 3: Implement** the two methods and the predicate, as the
  Interfaces block says.

- [ ] **Step 4: Run them and the subject tests**

  Run the session choice test file, then
  `test/services/designs/subject_test.rb`.

  Expected: PASS, both.

- [ ] **Step 5: Commit**

  ```bash
  git add app/services/designs/session_choice.rb app/models/design_turn.rb app/services/designs/subject.rb test/services/designs/session_choice_test.rb
  git commit -m "feat: a design turn's session is renewed once it has gone cold or grown large"
  ```

### Task 4: What a new session is told

**Files:**
- Create: `app/services/designs/thread_history.rb`
- Modify: `app/services/designs/prompt.rb` (`thread_message`), `app/services/designs/subject.rb` (`ThreadSubject#turn_message`)
- Test: create `test/services/designs/thread_history_test.rb`; modify `test/services/designs/prompt_test.rb` and `test/services/designs/subject_test.rb`

**Interfaces:**
- Produces:
  - `Designs::ThreadHistory.text(chat_session, before:, limit: Designs::ThreadHistory::LIMIT) → String | nil`,
    with `LIMIT = 20_000`.
    - It takes the chat's messages with `id < before`, oldest first.
    - The person's messages are those with role user and kind nil, as
      `The person: <content>`.
    - The replies are the assistant kinds summary, missing and blocked, as
      `You: …`, `You asked: …` and `You were blocked: …`.
    - Messages are separated by a blank line. Past `limit`, whole oldest
      messages are dropped, and the text starts with
      `(Earlier messages left out.)`.
    - With nothing before the message, it returns nil.
  - `Designs::Prompt.thread_message(…, history: nil, changed: nil)`. It adds
    `## This thread so far` and `## Changed on this branch` after
    `## The design repo now` and before `## Since your last turn`, and only
    when they are present.
  - `ThreadSubject#turn_message(request, turn: nil, worktree: nil, repo: nil, new_session: nil)`.
    - When `new_session` is nil, today's "first turn of the session" rule
      decides.
    - When it is true, the turn gets the full map, `history`, and `changed`.
      `changed` lists the paths that `repo.diff_names(base, @thread.branch, prefix)`
      gives for `"designs/"` and `"components/"`, where base is
      `@thread.base_sha.presence || Designs::Repo::MASTER`. It shows them as
      `- <path>` lines, at most 60, then `- … and N more`. On any error it is
      nil.

- [ ] **Step 1: Write the failing tests**
  - **`thread_history_test`:**
    - `"it gives the person's messages and the replies, oldest first, without hidden requests, notes or the message answered"`.
      Messages: user "Add usage"; summary "Added a usage chart."; system
      "Branch created"; user `kind: "request"` "Design as planned"; missing
      "Which period? Proposal: 30 days"; then the current user message "Make
      it weekly" as `before`.

      Expected: `"The person: Add usage\n\nYou: Added a usage chart.\n\nYou asked: Which period? Proposal: 30 days"`.
    - `"past the limit the oldest messages go, and it says so"`: three
      30-character messages and `limit: 70`. The text starts with
      `"(Earlier messages left out.)"` and holds the newest message only.
    - `"a thread with nothing before the message has no history"`: nil.
  - **`prompt_test`:**
    `"a new session's message carries the thread so far and the branch's changes, after the map and before the request"`.
    Call `thread_message(thread:, request: "Make it weekly", repo_map: "MAP", design: true, history: "The person: Add usage", changed: "- designs/admin/usage.html")`.
    - The positions of `"## The design repo now"` < `"## This thread so far"`
      < `"## Changed on this branch"` < `"## Request"`.
    - Without history and changed, neither heading appears.
  - **`subject_test`:**
    `"a turn that starts a new session gets the full map, the thread so far and the branch's changes; a resumed one gets the list alone"`.
    - Use a stand-in repo whose `diff_names` returns
      `["designs/admin/usage.html"]` for `"designs/"` and `[]` for
      `"components/"`.
    - `new_session: true` includes `"## This thread so far"`,
      `"## Changed on this branch\n- designs/admin/usage.html"` and
      `"The screen the person has open:"`.
    - `new_session: false` includes none of the three.
    - A stand-in repo that raises gives a message with no
      `"## Changed on this branch"`, and raises nothing.

- [ ] **Step 2: Run them**

  Run the three files.

  Expected: ERROR or FAIL on the new tests only.

- [ ] **Step 3: Implement** as the Interfaces block says.

- [ ] **Step 4: Run the three files**

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/services/designs/thread_history.rb app/services/designs/prompt.rb app/services/designs/subject.rb test/services/designs/thread_history_test.rb test/services/designs/prompt_test.rb test/services/designs/subject_test.rb
  git commit -m "feat: a design turn that starts a new session is told the thread so far and what its branch changed"
  ```

### Task 5: The turn job follows the choice

**Files:**
- Modify: `app/jobs/designs/turn_job.rb` (`run`, `ask_claude`, `converse`)
- Test: `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Consumes:
  - `Designs::SessionChoice.for` and `subject.renews_sessions?` (Task 3);
  - `subject.turn_message(request, turn:, worktree:, repo:, new_session:)`
    (Task 4).
- **Behavior:**
  - `run` computes the choice once for a non-check turn, before
    `ask_claude`.
  - `ask_claude` passes `new_session: choice != :resume` and `repo:`.
  - `converse` acts on the choice:
    - **:resume:** `resume_session` on the chat session's id;
    - **:start:** `start_session` under that id;
    - **:renew:** `session.update!(claude_session_id: SecureRandom.uuid)`,
      then `start_session` under the new id.

    Checks and the early-failure retry stay as they are.

- [ ] **Step 1: Write the failing tests**
  - `"a thread's later message on a session gone cold starts a new Claude session, kept on the chat, with the thread so far"`.
    - Setup:
      - from `thread_turn`, mark the first turn succeeded, started and
        finished 2 hours ago, `context_tokens: 40_000`;
      - add the summary "Added a counter.";
      - run `next_turn(session, "Make the counter red")` with `fake_claude`.
    - Assert:
      - `@calls.sole[0] == :start_session`;
      - the chat session's id changed, and equals
        `@calls.sole[1][:new_session_id]`;
      - the prompt includes `"## This thread so far"` and
        `"You: Added a counter."`.
  - `"a thread's later message on a warm, small session resumes it"`.
    - Setup: the same, with the first turn finished 5 minutes ago.
    - Assert:
      - `[:resume_session, old_id]`;
      - the prompt has no `"## This thread so far"`.
  - The existing tests stay unchanged and must pass:
    - "the first turn of a chat starts its Claude session, and every later
      one resumes it" (a task chat);
    - the retry tests.

- [ ] **Step 2: Run them**

  Expected: the two new tests FAIL (the job still resumes).

- [ ] **Step 3: Implement** as the Interfaces block says.

- [ ] **Step 4: Run the whole turn_job_test file**

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/jobs/designs/turn_job.rb test/jobs/designs/turn_job_test.rb
  git commit -m "feat: a thread's design turn resumes its session only while it is warm and small"
  ```

### Task 6: The map names theme.css instead of pasting it

**Files:**
- Modify: `app/services/designs/repo_map.rb`
- Test: `test/services/designs/repo_map_test.rb`, `test/services/designs/subject_test.rb`

**Interfaces:**
- Produces: when `design-system/theme.css` exists, `RepoMap.text` gives the
  line `Tokens: design-system/theme.css` right after the `Kit:` line, full or
  not. A full map keeps only the open screen whole. `THEME_LIMIT` goes.

- [ ] **Step 1: Change the tests first**
  - In repo_map_test, rename the first-turn test to `"on a session's first turn it gives the open screen whole and names the theme, and leaves a file too big for Claude to read"`.
    - Assert `assert_not_includes text, "--color-primary"`.
    - Assert `assert_includes text, "Kit: tailwind4\nTokens: design-system/theme.css"`.
  - In subject_test, the full-map test now asserts:
    - `assert_not_includes message, "@theme"`;
    - `assert_includes message, "Tokens: design-system/theme.css"`.

- [ ] **Step 2: Run them**

  Expected: FAIL (the theme is still pasted).

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run both files**

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/services/designs/repo_map.rb test/services/designs/repo_map_test.rb test/services/designs/subject_test.rb
  git commit -m "feat: a design turn's map names the theme instead of carrying it whole"
  ```

### Task 7: Design turns at medium effort

**Files:**
- Modify: `app/models/design_turn.rb`, `app/services/designs/subject.rb`, `app/jobs/designs/turn_job.rb` (`bounds`)
- Test: `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Produces:
  - `DesignTurn::DESIGN_EFFORT = "medium"`;
  - `#effort` on every subject: ThreadSubject gives `DesignTurn::DESIGN_EFFORT`,
    TaskSubject and SetupSubject give nil.
  - `bounds`'s last branch passes `effort: subject.effort`.

- [ ] **Step 1: Change the test**

  The test "a design turn keeps today's tools and no effort" becomes "a
  design turn keeps today's tools, at medium effort", with
  `assert_equal "medium", opts[:effort]`. Any setup test that asserts no
  effort stays as it is.

- [ ] **Step 2: Run it**

  Expected: FAIL (`nil`).

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run turn_job_test and setup_run_job_test**

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add app/models/design_turn.rb app/services/designs/subject.rb app/jobs/designs/turn_job.rb test/jobs/designs/turn_job_test.rb
  git commit -m "feat: a thread's design turns think at medium effort"
  ```

### Task 8: Editing rules that cut steps

**Files:**
- Modify: `app/services/designs/prompt.rb` (`BASE`, `COMPONENTS`, new `EDITING`, `thread_message`)
- Test: `test/services/designs/prompt_test.rb`

**Interfaces:**
- Produces: `Designs::Prompt::EDITING`, in `## This turn` of design turns
  only, right after `COMPONENTS`.
- Not here: section 3's last rule, that a new screen for several roles is one
  page component. It needs Phase 2's `data-show-for` (6a), and ships with it.
- **The exact copy:**
  - **`EDITING`** (squished):

    > Work in as few steps as you can: every step re-reads all you have read
    > so far. A change to something that several screens show goes into its
    > component once, never screen by screen. A text that repeats within a
    > file changes with one Edit that sets replace_all. Make all the edits
    > one file needs in one response, as several Edit calls side by side,
    > after reading it once. Keep each old_string short and unique: you write
    > it out just as you write the new text. Use Write only for a new file,
    > or for one that changes almost entirely. To find a place, Grep for it
    > (with line numbers), then read those lines with Read's offset and
    > limit; read a whole file only when you will change most of it.
  - **`BASE`'s components line** becomes:

    > - components/<name>/: <name>.html, README.md (what it is for, its
    >   parameters and its states) and, only for a component with more than
    >   one state, preview.html showing each.
  - **`BASE`'s re-read sentence** becomes:

    > before you reply, re-read the lines you changed (with Read's offset and
    > limit, not whole files): tags closed, paths and includes resolving.
  - **`COMPONENTS`'s parenthesis** becomes:

    > (its .html; a README.md with a line on what it is for, its parameters
    > and its states; a preview.html only when it has more than one state)

- [ ] **Step 1: Write the failing tests**
  - `"a design turn carries the editing rules, and a plan and a check do not"`:
    - EDITING is in a `design: true` message, and not in a `plan: true` or
      `check: true` one;
    - each of `"replace_all"`, `"offset and"`, `"one response"` and
      `"old_string"` is in EDITING.
  - `"a component gets a preview only when it has more than one state, and a turn re-reads only the lines it changed"`:
    - `"only when it has more than one state"` is in COMPONENTS;
    - `"re-read the lines you changed"` is in BASE.

- [ ] **Step 2: Run prompt_test**

  Expected: the two new tests FAIL.

- [ ] **Step 3: Implement the copy above.**

- [ ] **Step 4: Run prompt_test, subject_test and template_test**

  Expected: PASS, including "the files of a new design repo hold no passage
  of the base prompt" and "the skill shares no twelve words with the
  template".

- [ ] **Step 5: Commit**

  ```bash
  git add app/services/designs/prompt.rb test/services/designs/prompt_test.rb
  git commit -m "feat: design turns are told to edit in as few steps as they can"
  ```

### Task 9: The benchmark harness, and B2's baseline

**Files:**
- Create: `script/designs_benchmark.rb`
- Create (scratchpad, not the repo): `b2_history.rb`

**Interfaces:**
- Produces: `RAILS_ENV=production bin/rails runner script/designs_benchmark.rb b1 <transcript>`
  and `… b2`. Each prints one table row per run:
  - seconds, requests, tool calls (own and subagents');
  - largest context, output tokens, `total_cost_usd`;
  - files changed.

  Phases 1b and 2 reuse it.

- [ ] **Step 1: Write `b2_history.rb`.** This read-only runner is today's
  baseline for B2.
  - It takes the last 30 days of succeeded `design` turns with a commit that
    touched at most 2 files (`repo.files_changed_in` under `designs/` and
    `components/`).
  - It splits them into warm and cold. A turn is warm when the previous
    non-check turn finished less than 55 minutes before it started.
  - It prints for each group: the median seconds (finished minus started),
    the median cost (the turn's AiRun) and the count.

  Run it on the server **before** the deploy, and keep its output for the
  ledger.

- [ ] **Step 2: Write `script/designs_benchmark.rb`.** It reuses the real
  pieces:
  - **Session and thread:** an unsaved `ChatSession`, with a design thread
    built by `build_design_thread`, on project 15 and thread 6's task.
  - **The real turn's pieces:**
    - `Designs::Subject.for(session)`;
    - `subject.system_text` written to a temp file;
    - `Designs::TurnJob.new.send(:bounds, DesignTurn.new(kind:), subject)`;
    - `subject.with_mcp`;
    - `Designs::AppCopy.open` when `subject.app_copy?`;
    - `ClaudeCliService.new(...)`, with the job's keywords.
  - **The tree:** materialized in `Dir.mktmpdir` from the server clone at the
    run's commit, with `repo.ls_files(ref, "")` and `repo.read_file`.
  - **The messages:** `Designs::Prompt.thread_message` and
    `Designs::RepoMap.text`, as `ThreadSubject#turn_message` builds them.
  - **b1:**
    - **Inputs:** the commit is thread 6's `base_sha`. The task description
      and the focus come from the first user message of the transcript
      given (its `## Current description` and
      `## The person is looking at` sections).
    - **Plan run:** `PLAN_REQUEST` with `plan: true` and a full map, on
      `start_session`.
    - **Design run:** turn 98's own request, with `design: true`,
      `after_plan: true` and a list-only map, on `resume_session` of the
      plan's session.
  - **b2:**
    - **Commit:** master's head.
    - **First run:** on `designs/admin/designs-thread.html`, change the page
      title text to "Design threads". This is a design turn with a new
      session.
    - **B2a:** the follow-up "Make that title 'Threads' instead", resuming
      that session.
    - **B2b:** the same follow-up in a new session, with `history:` (the
      first request and its summary) and `changed:`.
  - **Measuring:** stats come from the streamed events:
    - requests, from distinct `message.id`;
    - tool calls, split by `parent_tool_use_id`;
    - the largest context, from usage;
    - the result's `total_cost_usd`.
  - **Attribution:** `AiRun::Attribution.new(workspace:, project:, area: "designs", item_label: "Benchmark <name>")`,
    so the cost shows in Consumption honestly.
  - **Cleanup:** the temp dirs, and the CLI's transcript folders for them.

- [ ] **Step 3: Check it loads**

  Run, locally:
  `bin/rails runner 'load "script/designs_benchmark.rb"' --help 2>&1 | head -3`,
  with the script printing its usage when given no run name.

  Expected: the usage line, and no NameError.

- [ ] **Step 4: Commit**

  ```bash
  git add script/designs_benchmark.rb
  git commit -m "chore: a benchmark that replays Designs turns on the server with the real prompts and flags"
  ```

### Task 10: Ship, then measure

**Files:** none new.

- [ ] **Step 1: Full suite**

  Run: `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_designs_speed bin/rails test > <workspace>/suite.log 2>&1; tail -30 <workspace>/suite.log`

  Expected: 0 failures, except the known date-dependent ones
  (reports_controller, holiday_request, workshop_report). Name them in the
  ledger.

- [ ] **Step 2: Final whole-branch review**

  Follow superpowers:executing-plans "Final Review": one fresh reviewer on
  the most capable model, then one fix pass.

- [ ] **Step 3: B2's baseline**

  Run Task 9 Step 1's `b2_history.rb` on the server, before the deploy.

- [ ] **Step 4: Deploy**
  - **Branch:** rebase onto origin/production if it moved, then push
    `HEAD:production` to origin and kacper.
  - **Wait for idle:** after a 5-minute tick, `ClaimedExecution` must be
    empty and `DesignTurn` queued/running must be 0.
  - **Deploy:** `bin/rails tailwindcss:build`, then `cap production deploy`.
  - **Check:** `/up` answers 200, and `DesignTurn.column_names` includes
    `context_tokens`.
  - **Mirror** main.

  Expected: release live; `/up` 200.

- [ ] **Step 5: Measure B1 and B2**

  Run, on the server:
  `bin/rails runner script/designs_benchmark.rb b1 <path of c5404c9a….jsonl>`,
  then `b2`.

  Expected: the B1 and B2 rows. Compare B1 with turn 98's baseline
  (plan 35 s; design 22.9 min, $11.19, 283 tool calls, context 81k → 385k),
  and B2 with the history medians.

- [ ] **Step 6: Report to Kacper (in Polish)**
  - Phase 0's answers, and any fall-back they trigger for 1b.
  - B1 and B2 against their baselines.
  - What ships next: the Phase 1b plan.
