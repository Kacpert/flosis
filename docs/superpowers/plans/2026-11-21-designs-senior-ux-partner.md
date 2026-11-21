# Designs senior UX/UI partner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A design thread's AI proposes before it builds anything new, catches UX/UI gaps itself, and checks its own screens in a browser after saying "done".

**Architecture:** Each thread now starts with a plan turn, also when started by typing. Later messages under rule (b) may end as proposals: a design turn that changes no file and asks, flagged `proposed`. The principles come as a new Library skill. After every design turn that commits, Flosis queues a `check` turn. It runs in a fresh Claude session with a design-only browser (`browser.mjs`) and fixes only what broke on screen.

**Tech Stack:** Rails 8.1, Minitest, Solid Queue, Claude CLI via ClaudeCliService, Node + Playwright MCP server (lib/designs_crawler).

**Spec:** `docs/superpowers/specs/2026-11-21-designs-senior-ux-partner-design.md`

## Global Constraints

- Work on `production` in /Users/kacper/gold. Run `git branch --show-current` before each commit, `git add` explicit paths only, and add no Claude trailer to commit messages.
- Plan turn bounds stay: 300 s, $3, effort "medium", tools Read, Glob, Grep.
- Check bounds: 600 s, $5, effort "medium". Widths 1160 and 1024 px, viewport height 860, at most 6 screens.
- Fixed copy: "Checking it on screen now; the preview is already up to date." / "Not checked on screen: an import is using the browser." / "On-screen check stopped: a new message came first. Nothing it changed was kept."
- The skill has key "senior-product-designer", name "Senior product designer", kind "skill" and is active. No Library text may share twelve words in a row with lib/designs_template, so examples stay under twelve words.
- The base prompt (`designs-base`) text does not change.
- Changed `lib/designs_crawler/*.mjs` files are uploaded to `shared/designs_crawler` at deploy. `cap deploy` does not do it.

## Review Focus

1. **A message while a check waits or runs.** The check stops quietly with the fixed note, and the person's turn runs next. Pinned in Task 5.
2. **The answer to a proposal is built.** It is never proposed again, so the chat cannot loop. Pinned in Task 3.
3. **A typed thread's first message with images.** Its plan turn reads the images. Pinned in Task 3.
4. **An import running when a check would queue or start.** No browser starts and the note shows instead of the "Checking…" sentence. Pinned in Task 5.
5. **A check that changes nothing.** It neither moves the thread's focus nor refreshes the person's page. Pinned in Task 5.

---

### Task 1: Turn flags and the check kind

**Files:**
- Create: `db/migrate/20261121010000_add_proposal_flags_to_design_turns.rb`
- Modify: `app/models/design_turn.rb`, `db/schema.rb`
- Test: `test/models/design_turn_test.rb`

**Interfaces:**
- Produces:
  - columns `design_turns.may_propose` and `design_turns.proposed` (boolean, default false, null false);
  - `DesignTurn::KINDS` gains `"check"`, with `check?`;
  - the constants `CHECK_TIMEOUT_SECONDS = 600`, `CHECK_BUDGET_USD = 5`, `CHECK_EFFORT = "medium"`;
  - `DesignTurn.check_stale_after` (600 s + 5 min);
  - `succeed!(commit_sha:, proposed: false)`;
  - `awaits_answer?` (succeeded and plan or proposed).

- [ ] Write failing tests:
  - "a check turn goes stale after its own bound";
  - "a proposal awaits an answer, a design that built does not".

  The first test: a running check started 11 minutes ago is failed by `fail_stale!`, while one started 9 minutes ago is not. For a design started 9 minutes ago, `stale?` is false.
- [ ] Run `bin/rails test test/models/design_turn_test.rb`. Expect FAIL.
- [ ] Add the migration and model code. In `fail_stale!`, give "check" its own bucket and exclude it from the default one. `stale?` uses `check_stale_after` for checks.
- [ ] Run `bin/rails db:migrate` and the tests. Expect PASS, and `db/schema.rb` shows both columns.
- [ ] Commit: `feat: design turns can be a check, and can end as a proposal`.

### Task 2: The texts: plan, direction first, check, and the skill

**Files:**
- Modify: `app/services/designs/prompt.rb`, `app/services/designs/threads.rb` (the PLAN_REQUEST text only)
- Create: `db/migrate/20261121010100_add_senior_product_designer_skill.rb`
- Test: `test/services/designs/prompt_test.rb`, `test/migrations/add_senior_product_designer_skill_test.rb`

**Interfaces:**
- Produces:
  - the constants `Designs::Prompt::PLAN`, `DIRECTION_FIRST`, `CHECK` and `SENIOR_DESIGNER_SKILL`. The constants `AFTER_PLAN`, `SCREENS_ONLY`, `STATES` and `COPIES` stay.
  - `Designs::Prompt.thread_message(thread:, request:, repo_map: nil, screens_only: false, after_plan: false, plan: false, may_propose: false, check: false, check_note: nil)`. "This turn" holds, in order, the following, each only when its option is set:
    1. PLAN, when plan;
    2. CHECK, when check;
    3. SCREENS_ONLY;
    4. STATES, when screens_only or plan;
    5. COPIES;
    6. DIRECTION_FIRST, when may_propose and not after_plan;
    7. AFTER_PLAN.
  - A check message has only the Thread, This turn and Request sections.
  - `check_note` becomes a section, "## Since your last turn", before This turn.
  - `Designs::Threads::PLAN_REQUEST = "Plan the design of this task."`.
- Content:
  - **PLAN.** The spec's §1: change no file; at most about four short lines (the understanding, left out when obvious; the placement, respecting each view's purpose; each new value's format as exact strings, one per variant); `<missing>` only where a standard cannot settle, each ending "Proposal: "; never ask what the notes, the task or the conversation settle; with nothing open, end "No doubts, designing now.".
  - **DIRECTION_FIRST.** The spec's §2 rule. It ends "This replaces what the base prompt says about never stopping to ask."
  - **AFTER_PLAN.** It now names "your plan or proposal".
  - **CHECK.** The spec's §4: the flosis_browser tools; what the base prompt says about having no browser does not hold; `design_shot` at 1160 and 1024 px (full_page when it scrolls); `check_design`; each state of the switcher the last turn touched, by `path#state`; what to look for; fix only what broke, with the smallest change; no file changed when nothing broke; a summary of one line starting "Checked on screen:".
  - **SENIOR_DESIGNER_SKILL.** The spec's §3 list, verbatim in meaning, as bullets, with the reply rule: at most three short sentences, exact strings, no file names. It says it tightens what the base prompt says about the summary.

- [ ] Write the failing tests:
  - "a plan turn's message carries the plan's rules";
  - "a design turn that may propose is told to propose a direction first, unless it answers a plan";
  - "a check turn's message holds only the thread, the check's rules and its request";
  - "the note on what a check changed comes before This turn";
  - "the skill shares no twelve words with the template", using the same helper as BASE's test;
  - migration tests: "the skill is added once, active, as version 1" and "a library that already has the skill keeps it as it is".
- [ ] Run `bin/rails test test/services/designs/prompt_test.rb test/migrations/add_senior_product_designer_skill_test.rb`. Expect FAIL.
- [ ] Implement the constants, the `thread_message` options and the migration. The migration has its own Entry/Version classes, as in UpdateDesignsBasePromptForV2, and returns early when the key exists.
- [ ] Run the tests and `bin/rails db:migrate`. Expect PASS.
- [ ] Commit: `feat: a plan's, a proposal's and a check's rules, and the senior product designer skill`.

### Task 3: Proposals: a plan at every start, and rule (b) after it

**Files:**
- Modify: `app/services/designs/threads.rb`, `app/services/designs/subject.rb` (ThreadSubject), `app/jobs/designs/turn_job.rb`, `app/views/workshop/designs_module/_messages.html.erb`
- Test: `test/services/designs/threads_test.rb`, `test/services/designs/subject_test.rb`, `test/jobs/designs/turn_job_test.rb`, `test/controllers/workshop/designs_module_controller_test.rb`

**Interfaces:**
- Consumes: Task 1's columns, `awaits_answer?` and `succeed!(proposed:)`; Task 2's `thread_message` options.
- Produces:
  - `queue_turn(thread, user, text, kind:, visible:, then_merge:, images:, may_propose: false)`;
  - `ThreadSubject#after_plan?(turn)`, true when the last earlier turn other than a check `awaits_answer?`.

- [ ] Write the failing tests:
  - **threads_test:**
    - "a fresh thread's first message plans before it designs": a kind "plan" turn, the visible message, and the images attached to it;
    - "a later message may propose";
    - "Update designs may propose";
    - "Try again keeps whether the turn may propose";
    - "Design with these proposals starts the design after a proposal".
  - **subject_test:**
    - "a turn after a proposal is told it is settled and is not asked to propose";
    - "a turn that may propose, after a design that built, is asked to propose a direction first".
  - **turn_job_test:**
    - "a design turn that may propose, changes nothing and asks, is a proposal": proposed true, nothing committed, the missing message posted;
    - "a design turn that built is no proposal, even with open questions";
    - "a plan turn on a typed thread reads the images sent with its message".
  - **designs_module_controller_test:** "a proposal offers Design with these proposals".
- [ ] Run these test files. Expect FAIL on the new tests.
- [ ] Implement each piece:
  - `message!`: plan on a fresh thread, else a design with may_propose.
  - `update_description!`: may_propose.
  - `retry!` copies may_propose.
  - `go!` takes `last&.awaits_answer?`.
  - ThreadSubject passes `may_propose: turn.may_propose && !after_plan?(turn)`.
  - TurnJob#finish gets `proposed: turn.may_propose && sha.nil? && output.missing.any?` for design turns.
  - The view's button uses `turns.last&.awaits_answer?`.
- [ ] Run all Designs tests: `bin/rails test test/services/designs test/jobs/designs test/controllers/workshop test/models/design_turn_test.rb`. Expect PASS.
- [ ] Commit: `feat: every design thread starts with a plan, and later messages may end as a proposal`.

### Task 4: A design-only browser with screenshots at a width

**Files:**
- Modify: `lib/designs_crawler/browser.mjs`
- Test: `lib/designs_crawler/test/browser.test.mjs`

**Interfaces:**
- Produces:
  - config `{ designOnly: true, worktree, viewport }`, where contexts and baseUrl may be absent. It registers only `design`, `design_shot`, `click_design` and `check_design`.
  - The `design_shot` tool, `{ path, width?: int 320..2560, full_page?: bool }`, returns an image at that width, using the viewport's height. A path may end in `#state`: the hash goes on the URL, not the file.
  - `shot()` takes its size from `page.viewportSize()`.

- [ ] Write the failing test "a design-only browser lists its four tools and shows a design at a given width". It checks the tool list, a PNG width of 1024 (bytes 16–19), and that `designs/admin/home.html#second` opens.
- [ ] Run `cd lib/designs_crawler && node --test test/browser.test.mjs`. Expect FAIL. A skip means Chromium cannot launch: install it with `npx playwright install chromium`.
- [ ] Implement the design-only registration, `design_shot`, the hash handling in `showDesign`, and `shot()` sizing. The existing setup tools and test stay as they are, plus `design_shot`.
- [ ] Run the node tests. Expect PASS.
- [ ] Commit: `feat: the design browser can run on its own and show a design at a given width`.

### Task 5: The check after a build

**Files:**
- Modify:
  - `app/services/designs/threads.rb`
  - `app/services/designs/subject.rb`
  - `app/jobs/designs/turn_job.rb`
  - `app/services/designs/turn_activity.rb`
  - `app/views/workshop/designs_module/_turn.html.erb`
  - `app/views/workshop/designs_module/_messages.html.erb`
  - `app/javascript/controllers/designs_poll_controller.js`
- Test: `test/jobs/designs/turn_job_test.rb`, `test/services/designs/threads_test.rb`, `test/services/designs/subject_test.rb`, `test/services/designs/turn_activity_test.rb` (if present), `test/controllers/workshop/designs_module_controller_test.rb`

**Interfaces:**
- Consumes:
  - from Task 1: `check?` and the check bounds;
  - from Task 2: `thread_message(check:, check_note:)`;
  - from Task 4: the browser config and its tools.
- Produces:
  - `Designs::Threads.new_check(thread, after:, summary:, chips:)` returns a queued check turn, not enqueued. Its hidden request lists the person's request, the summary and at most 6 screens.
  - `Designs::Threads.stop_checks!(thread, user:)`.
  - `Designs::Subject::CHECK_TOOLS` = the four `mcp__flosis_browser__…` names.
  - `ThreadSubject#with_mcp(worktree, read_only: false, browser: false)`.
  - `ThreadSubject#chips(repo, from, to, move_focus: true)`.

- [ ] Write the failing tests:
  - **turn_job_test:**
    - "a design turn that commits ends its reply with the checking sentence and queues a check": the check exists before the reply's transaction ends, and the job is enqueued;
    - "no check follows a plan, a turn that changed nothing, a components turn, a resolve-conflicts turn or a check";
    - "a check runs in a fresh session with the design browser, on the check's bounds": `start_session` with a new id, the chat session's id unchanged, the tools, an mcp_config naming browser.mjs, and 600/5/medium;
    - "a check that fixes something commits it and says what it fixed, without moving the thread's focus";
    - "a check skipped while an import's unit runs posts the note and starts no Claude";
    - "a design turn during an import gets the note instead of the checking sentence";
    - "a stopped check posts the quiet note, not an error";
    - "the turn after a check that changed something is told what it changed";
    - "a failed check does not count as the session's earlier failure".
  - **threads_test:**
    - "a person's message stops a waiting check quietly";
    - "a person's message asks a running check to stop".
  - **designs_module_controller_test:**
    - "a running check reads Checking on screen";
    - "the chat polls while a check runs but marks the screen idle".
- [ ] Run these test files. Expect FAIL on the new tests.
- [ ] Implement the job side:
  - TurnJob picks the bounds by kind (plan / check / other).
  - A check starts a fresh session each try, with no update to the chat session's id. `converse`'s started query and `first` (the repo map) exclude checks.
  - `earlier_failure` ignores checks, and returns nil for a check.
  - In `run`, a check returns early with the import note when `DesignSetup.unit_running?`.
  - `finish` creates the check inside its transaction when a design turn committed and no import unit runs. It appends the sentence then, or the import note otherwise, and enqueues after the commit.
  - `fail_turn` posts the quiet note for a stopped check.
- [ ] Implement the thread and display side:
  - `Threads.message!` calls `stop_checks!` first.
  - ThreadSubject gives a check its message, tools, browser MCP config and bounds, and leaves the focus where it is. The next turn's `check_note` is the summary of the check right before it, when that check committed.
  - TurnActivity labels the four browser tools:
    - "Looking at <path> at <width> px"
    - "Checking <path>"
    - "Opening <path>"
    - "Clicking through the design"
  - `_turn` reads "Checking on screen".
  - `_messages` adds `data-designs-poll-busy-value`: any active turn that is not a check.
  - The poll controller refreshes the page when busy ends or a commit lands, and keeps polling while active.
- [ ] Run all Designs tests and `cd lib/designs_crawler && npm test`. Expect PASS.
- [ ] Commit: `feat: after a build the thread's AI checks its screens in a browser while the person already looks`.

### Task 6: Ship

- [ ] Run `bin/rails test`, with `PARALLEL_WORKERS=1` if the pg gem segfaults. Compare any failures with the known date-dependent ones (reports_controller, holiday_request, workshop_report).
- [ ] Run a fresh whole-branch review (superpowers:requesting-code-review). Fix what it confirms and re-run the tests.
- [ ] `git push origin production` and `git push kacper production`.
- [ ] Deploy:
  1. Make a clean worktree of `production` in the scratchpad and symlink `.env`.
  2. Run `bin/rails tailwindcss:build` there.
  3. Check `SolidQueue::ClaimedExecution` on the server, and that no design turn or import unit runs.
  4. Run `bundle exec cap production deploy` right after a 5-minute tick.
- [ ] Upload the changed `lib/designs_crawler/browser.mjs` (and any other changed `.mjs`) to `~/domains/clar.rubyonsaas.com/app/shared/designs_crawler/`.
- [ ] Verify on the server with rails runner:
  - both columns exist;
  - the skill entry exists with version 1;
  - `Designs::Library.compose(Project.find(15)).text` includes "Senior product designer".
- [ ] Run `node --test` against the uploaded browser, or a one-off design_shot through the MCP client, from shared/designs_crawler.
- [ ] Merge onto origin `main`: a merge commit whose tree is production's, as `project_trunk_is_production_branch` describes.
