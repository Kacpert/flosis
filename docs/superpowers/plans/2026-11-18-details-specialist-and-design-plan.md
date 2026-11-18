# Details as a specialist, and Design that starts with a plan — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Details chat proposes like a specialist in short messages and drafts in Kacper's format; a design thread started from a task first posts a quick read-only plan, and designs at once when it has no doubts.

**Architecture:** Part 1 is prompt text in `ChatSessionsController#build_initial_prompt` (shared by Workshop Details and the Jira Tasks board). Part 2 adds a `plan` turn kind: `start_from_task!` queues it, `Designs::TurnJob` runs it with read-only tools, a lower effort and small limits, and queues the design turn itself when the plan has no `<missing>` block. Otherwise a "Design with these proposals" button (or the person's answer) starts the design turn.

**Tech Stack:** Rails 8.1, Minitest 6, Turbo/Stimulus, Claude CLI 2.1.251 (`--tools`, `--effort`).

**Spec:** `docs/superpowers/specs/2026-11-18-details-specialist-and-design-plan-design.md`

## Global Constraints

- Commits carry no Co-Authored-By or Claude-Session trailer.
- Tests run one file at a time: `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_details_specialist bin/rails test <file>`. Never two test processes on that DB. Never the real Claude CLI in a test.
- Before pushing a change to `app/controllers/chat_sessions_controller.rb`, tell the gold-83 session.
- UI copy in English; chat messages "at most three short sentences".

## Review Focus

1. The person writes while the plan runs: when the plan then ends with no questions, no second design turn is queued (their message's turn carries on). Test in Task 4.
2. A plan turn fails (time limit, cost cap): Try again runs a plan turn again, not a design turn. Test in Task 5.
3. "Design with these proposals" clicked twice: the second click is refused while the design turn waits or runs. Test in Task 5.
4. A thread whose last turn is a plan that asked questions, after the person answered: the button is gone (the last turn is now the design turn). Test in Task 5.
5. The Details prompt keeps Step 0 (briefed and unbriefed), the code investigation step, the handoff sections and the description-panel note. The existing tests in `chat_sessions_controller_test.rb` stay green in Task 1.

---

### Task 1: The Details prompt: specialist, short messages, screens covered, Kacper's template

**Files:**
- Modify: `app/controllers/chat_sessions_controller.rb` (`build_initial_prompt`: Role, Step 2, Step 3 template, Start now; `investigation_step` and `no_code_step`: the first message ends with a proposal or a question)
- Test: `test/controllers/chat_sessions_controller_test.rb`

**Interfaces:** none produced for later tasks.

- [ ] **Step 1: Write the failing tests** (same bare-controller seam as "the prompt tells the AI to point the reader at the description panel")

```ruby
test "the details prompt makes the AI a specialist who proposes, in short messages" do
  prompt = details_prompt
  assert_includes prompt, "You are a specialist"
  assert_includes prompt, "Ask only about what a standard cannot settle"
  assert_includes prompt, "At most three short sentences"
  assert_includes prompt, "One decision per message, put as a proposal to confirm"
end

test "before drafting, the details AI settles where each new piece shows and how" do
  prompt = details_prompt
  [ "where it shows (screen, tab, spot)", "who sees it", "its default (shown or hidden, on or off)",
    "one item or a total, and for which period", "its format, with an example", "empty and error states" ].each do |item|
    assert_includes prompt, item
  end
end

test "the draft is short, laid out by feature or place, with no user story or file paths" do
  prompt = details_prompt
  [ "## Background", "## User story", "## Requirements", "Implementation pointers" ].each { |old| refute_includes prompt, old }
  [ "2–3 sentences, no heading", "## Rules", "## Out of scope", "## Acceptance criteria", "## Open questions", "Proposal:" ].each do |part|
    assert_includes prompt, part
  end
end
```

with a private helper `details_prompt` that builds the bare controller as the existing tests do.

- [ ] **Step 2: Run them, expect 3 failures** on the missing phrases.

- [ ] **Step 3: Rewrite the prompt** so each tested phrase appears in its place, following the spec's Part 1. Keep the phrases the existing tests pin ("Talk PRODUCT, not implementation", "Do NOT dump code at the user", "no line numbers", "PLAIN-LANGUAGE summary", "REMOVED from the chat", "Description panel on the right", "version selector", "never write as though the ticket were in the chat"). The first message after investigating: a 1–2 sentence plain-language summary, then the first proposal to confirm.

- [ ] **Step 4: Run the whole file**, expect all green.

- [ ] **Step 5: Commit** `feat: the Details chat proposes like a specialist, in short messages, and drafts in Kacper's format`

### Task 2: ClaudeCliService takes an effort level

**Files:**
- Modify: `app/services/claude_cli_service.rb` (`initialize` gains `effort: nil`; `build_command` pushes `"--effort", @effort` after `--tools` when set)
- Test: `test/services/claude_cli_service_test.rb` (beside the `--tools` test)

**Interfaces:**
- Produces: `ClaudeCliService.new(..., effort: "medium")` → command contains `--effort medium`; `effort: nil` adds nothing.

- [ ] **Step 1: Failing test** `"an effort level reaches the CLI, and none is passed by default"`: the built command includes `["--effort", "medium"]` in order for `effort: "medium"`, and has no `"--effort"` without it.
- [ ] **Step 2: Run, expect FAIL** (unknown keyword `effort`).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the file, expect green.**
- [ ] **Step 5: Commit** `feat: Claude CLI calls can set an effort level`

### Task 3: A thread started from a task begins with a plan turn

**Files:**
- Modify: `app/models/design_turn.rb` (`KINDS` + `"plan"`; `PLAN_TIMEOUT_SECONDS = 300`, `PLAN_BUDGET_USD = 3`, `PLAN_EFFORT = "medium"`; `def plan? = kind == "plan"`; the KINDS comment names it)
- Modify: `app/services/designs/threads.rb` (`START_FROM_TASK` → `PLAN_REQUEST`; new `DESIGN_AS_PLANNED`, `GO_WITH_PROPOSALS`; `start_from_task!` queues `kind: "plan"`)
- Test: `test/services/designs/threads_test.rb`, `test/models/design_turn_test.rb`

**Interfaces:**
- Produces: `DesignTurn#plan?`, the three `DesignTurn::PLAN_*` limits, `Designs::Threads::PLAN_REQUEST`, `::DESIGN_AS_PLANNED`, `::GO_WITH_PROPOSALS`.

Copy (exact):

- `PLAN_REQUEST`: "Before you design, make sure you know what to do. Read the task's current description and the screens it touches; change no file in this turn. In the summary, give your plan in at most five short lines: what you will design and where (screen and spot), reusing the screens that already cover it. Ask in a missing block only where a standard answer will not do, one question each, ending with \"Proposal: \" and your answer. With nothing to ask, end the summary with \"No doubts, designing now.\""
- `DESIGN_AS_PLANNED`: "No doubts: design it as planned. Say which screens you changed, and what is left to decide."
- `GO_WITH_PROPOSALS`: "Go with your proposals for the open questions, and design it as planned. Say which screens you changed, and what is left to decide."

- [ ] **Step 1: Failing tests**: `"a thread started from a task plans first, out of sight"`: the one turn is `kind == "plan"`, its message is `PLAN_REQUEST` with `kind == "request"`. And in design_turn_test, `"a plan turn is a kind of its own"`: `DesignTurn.new(kind: "plan").plan?` is true, and a plan turn validates.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run both files, expect green.**
- [ ] **Step 5: Commit** `feat: a design thread started from a task begins with a plan turn`

### Task 4: TurnJob runs a plan read-only and quick, and designs at once when it has no questions

**Files:**
- Modify: `app/jobs/designs/turn_job.rb` (`PLAN_TOOLS = %w[Read Glob Grep]`; `ask_claude` passes plan turns `tools: PLAN_TOOLS`, `max_budget_usd: DesignTurn::PLAN_BUDGET_USD`, `timeout: DesignTurn::PLAN_TIMEOUT_SECONDS`, `effort: DesignTurn::PLAN_EFFORT`, other kinds as today with no effort; `run` calls `carry_on(turn, output) if turn.plan?` after `finish`)
- Modify: `app/services/designs/threads.rb` (`design_as_planned!(thread, user:)` → `queue_turn(thread, user, DESIGN_AS_PLANNED, visible: false)`)
- Test: `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Consumes: Task 2's `effort:`; Task 3's `plan?`, limits and `DESIGN_AS_PLANNED`.
- Produces: `Designs::Threads.design_as_planned!(thread, user:) → DesignTurn`.

`carry_on(turn, output)`: does nothing when `output.missing.any?`, or when the session already has a queued or running turn other than this one; otherwise calls `design_as_planned!` with the plan's `chat_message.user`. An error there is logged, never raised: the plan has succeeded.

- [ ] **Step 1: Failing tests** (a helper `plan_turn(repo, base)` like `thread_turn`, with `kind: "plan"` and the request `PLAN_REQUEST`):
  - `"a plan turn runs read-only, at a lower effort and on the plan's limits"`: the factory's opts have `tools: %w[Read Glob Grep]`, `effort: "medium"`, `max_budget_usd: 3`, `timeout: 300`; the turn succeeds with no commit.
  - `"a plan with no questions goes straight on to design"`: reply `"<summary>Counter under long answers, on the form.\nNo doubts, designing now.</summary>"` → a new queued `kind: "design"` turn whose message is `DESIGN_AS_PLANNED` (kind `"request"`), and a `Designs::TurnJob` enqueued for it.
  - `"a plan with questions waits for the person"`: reply with a `<missing>Where…? Proposal: in the header.</missing>` block → no new turn; the question is in the chat (kind `"missing"`).
  - `"a plan does not start a second design turn when the person already wrote"`: a queued design turn from a person's message exists before the plan runs → after it, still exactly that one queued turn.
  - `"a design turn keeps today's tools and no effort"`: an ordinary thread turn's opts have `tools: Designs::TurnJob::TOOLS` and `effort: nil`.
- [ ] **Step 2: Run, expect the failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the file, expect green.**
- [ ] **Step 5: Commit** `feat: a plan turn reads only and is quick, and with no questions the design starts at once`

### Task 5: "Design with these proposals", the Planning label, and Try again on a plan

**Files:**
- Modify: `app/services/designs/threads.rb` (`go!(thread, user:)`; `NO_PLAN = "There is no plan waiting for an answer."`)
- Modify: `app/controllers/workshop/design_threads_controller.rb` (`go`, like `retry`), `config/routes.rb` (`post :go` in the design_threads member block)
- Modify: `app/views/workshop/designs_module/_messages.html.erb` (the button), `_turn.html.erb` (`doing` is `"Planning"` for a plan turn)
- Test: `test/services/designs/threads_test.rb`, `test/controllers/workshop/design_threads_controller_test.rb`, `test/controllers/workshop/designs_module_controller_test.rb`

**Interfaces:**
- Consumes: Task 3's `plan?` and `GO_WITH_PROPOSALS`.
- Produces: `Designs::Threads.go!(thread, user:) → DesignTurn`; route helper `go_workshop_design_thread_path`.

`go!` refuses a merged thread (ArgumentError), an importing or busy one (Busy), and one whose last turn is not a succeeded plan (ArgumentError `NO_PLAN`); otherwise `queue_turn(thread, user, GO_WITH_PROPOSALS, visible: false)`.

The button shows under the chat when the last turn is a succeeded plan, nothing is active, the thread is open and not importing: `button_to go_workshop_design_thread_path(thread)` labelled "Design with these proposals" (same form options as Try again), with the hint "Or answer the questions above in your own words."

- [ ] **Step 1: Failing tests**:
  - threads_test `"Design with these proposals starts the design turn after a plan that asked"`: last turn a succeeded plan → `go!` queues a design turn with `GO_WITH_PROPOSALS` (hidden).
  - threads_test `"Design with these proposals is refused without a plan waiting, or twice"`: no plan → ArgumentError `NO_PLAN`; after one `go!`, a second raises Busy.
  - threads_test `"Try again on a failed plan plans again"`: a failed plan turn → `retry!` makes a `kind: "plan"` turn.
  - designs_module_controller_test `"a plan that asked offers Design with these proposals until the person answers"`: button and hint present after a succeeded plan; gone once a design turn follows.
  - designs_module_controller_test `"a running plan says Planning"`.
  - design_threads_controller_test `"go starts the design and goes back to the thread"`: POST redirects to the thread; a design turn is queued.
- [ ] **Step 2: Run, expect the failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the three files, expect green.**
- [ ] **Step 5: Commit** `feat: a plan that asked can be taken as proposed, and a running plan says Planning`

### After the tasks

Full suite on the branch (the 6 date and og-image failures known on production are expected), a browser check of the plan, button and Planning label (dumped page + harness under `.playwright-mcp/`), a final review, then push, deploy on a quiet tick and mirror main.
