# Designs Imports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Designs import gets a page that stays (status, Needs you cards, Built, Missing feature?), with retry, reply, add, set aside, a session-limit pause, and a resync from the app whose changes to a thread's work wait for Accept or Reject.

**Architecture:** An import stays a `DesignSetup` (kinds first, reimport, resync) and its features `DesignSetupFeature` rows with new states (waiting, review, set_aside). `Designs::SetupRunJob` keeps running one unit per job; after an import finishes it also runs its queued features, each on its own branch `wip/import-<setup>-<key>` from master, landing each on master through `Designs::ImportLanding` as a `DesignMerge` (how "import"), unless `Designs::ThreadWork` finds it would change lines a thread put on master: then the feature waits as a review. The pages render inside Designs (`tab=imports`) and, for a first import still without master, on the setup page.

**Tech Stack:** Rails 8.1.3, Ruby 3.4.1, Minitest, Hotwire/Stimulus, Tailwind 4, Solid Queue 1.4, git through `GitRunner`, Node 20 + Playwright for lib/designs_crawler.

**Spec:** docs/superpowers/specs/2026-11-04-designs-imports-design.md (approved 2026-11-04).

## Global Constraints

- UI copy (English, verbatim): "Imports", "N need you", "Waiting for you", "Couldn't finish", "Not started", "Review what comes in", "Done · N notes", "Set aside", "Not needed", "Missing feature?", "Add", "Send and continue", "Retry", "Retry all N", "Tell the AI something first…", "Accept", "Reject", "Comes in", "Kept", "Replaced", "Open screens: proposed · master".
- The "Imports" line: one line in the Designs left panel under Merge history, same size as its neighbours, no badge, no pill, nothing in the app's sidebar; lit per person while an import has settled since that person last opened it; "N need you" on its right while any card waits, else the date of the last import.
- Seeing Imports needs the designs permission; starting an import and every card action need configuration.
- Production is MariaDB: every JSON column is typed in its model (`attribute :x, :json, default:`).
- Tests: run one file at a time with `PARALLEL_WORKERS=1 bin/rails test <file>`, never two test processes at once; never the real Claude CLI (turn runners and `claude_factory` are stood in for); never gold_development.
- Commits carry no Co-Authored-By or session trailers; messages in English.
- Shipping: verified increments merge into production, push origin and kacper, deploy right after a quiet 5-minute tick (no `SolidQueue::ClaimedExecution`), then mirror main.
- Only one import unit runs per server at a time.

## Review Focus

1. A deploy kills a worker in the middle of a queued feature of a finished import: the resume job must pick it up (Task 3 test "a follow-up a deploy cut off is picked up again").
2. A double click on Retry or Retry all: each feature is queued once and the work runs once (Task 3 test "Retry all queues every feature that needs you, once").
3. A limit message whose reset cannot be read: the run pauses 30 minutes instead of failing (Task 4 test "a limit whose reset cannot be read pauses thirty minutes").
4. An import page for an import whose map found nothing or that stopped: it shows the error and Retry, never a blank page (Task 2 test "a stopped import shows why, with Retry").
5. Master moved under a feature's branch while it was built: landing says why it couldn't land instead of raising (Task 3 test "a feature that collides with master couldn't land, and says why").

---

### Task 1: Import states

**Files:**
- Create: `db/migrate/20261104020000_add_imports_to_design_setups.rb`, `app/models/design_import_view.rb`, `app/services/designs/usage_limit.rb`
- Modify: `db/schema.rb`, `app/models/design_setup.rb`, `app/models/design_setup_feature.rb`, `app/models/chat_session.rb`, `app/models/design_merge.rb`
- Test: `test/models/design_setup_imports_test.rb`, `test/services/designs/usage_limit_test.rb`

**Interfaces:**
- Produces: columns `design_setups.kind` (string, default "first", null false; backfilled "reimport" where design_thread_id), `app_commits` (json), `paused_until`, `settled_at` (backfilled from finished_at), `since_setup_id`; `design_setup_features.attempts` (int 0), `branch`, `queued_at`, `question` (text), `reply` (text), `review` (json), `resets_at`, `source` (string, default "map"), `changes` (text); `chat_sessions.design_setup_id`; table `design_import_views(design_setup_id, user_id, seen_at)` unique on the pair.
- Produces: `DesignSetup::KINDS = %w[first reimport resync]`, `#title -> String`, `#summary -> String`, `#needs_you -> Relation`, `#busy? -> Boolean`, `#settle!`, `#seen_by!(user)`, `#lit_for?(user) -> Boolean`, `.lit_for?(project, user)`, `scope :first_imports`, `scope :newest_first`; `DesignSetupFeature::STATUSES` + `waiting review set_aside`, `scope :needs_you`, `#problem -> :waiting | :review | :limit | :unreadable | :error | :paused | nil`, `#queue!(reply: nil, fresh: true)`; `DesignMerge::HOWS` + "import" (label "Flosis AI · import"); `Designs::UsageLimit.hit?(text) -> Boolean`, `.reset_at(text, now:) -> Time`, `FALLBACK = 30.minutes`.

- [ ] **Step 1: Write the failing tests**

`usage_limit_test.rb`: "hit? matches the CLI's limit messages" (`"Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)"`, `"Claude AI usage limit reached|1762243200"` true; `"Failed to parse Claude response"` false); "reads the reset hour in its zone, later today" (now 2026-11-03 06:50 Warsaw → 08:00 Warsaw same day); "rolls to the next day once the hour has passed" (now 09:00 → next day 08:00); "reads minutes and a date" (`"resets Nov 5, 8:30pm (Europe/Warsaw)"`); "reads an epoch"; "a limit whose reset cannot be read pauses thirty minutes".

`design_setup_imports_test.rb`: "a first import's title names the app's host" (`"First import · from app.flosis.com"`); "a resync's title names the import it starts from" (`"Changes since Nov 3"`); "summary counts what was built" (`"6 of 11 features built"`; resync `"3 updated · 1 new"`); "needs you is the waiting, review, failed and paused features, not those set aside"; "the line is lit until the person opens the import, and again once it settles"; "an import is busy while a feature waits in its queue"; "a feature's problem comes from what happened" (session-limit error → :limit, `"Failed to parse Claude response"` → :unreadable, other → :error, waiting → :waiting); "queue! clears the last attempt and keeps the branch only to go on".

- [ ] **Step 2: Run them to see them fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/designs/usage_limit_test.rb` then the model file.
Expected: FAIL (uninitialized constant Designs::UsageLimit; unknown attribute kind).

- [ ] **Step 3: Implement**

Migration with the columns and backfills above; schema.rb by hand (version 2026_11_04_020000). `UsageLimit.reset_at` reads `resets (<month day>, )?<h>(:<mm>)?(am|pm) (<zone>)?` in the zone (default `Time.zone`), the next such time after `now`; `|<epoch>`; else `now + FALLBACK`. `#problem` for failed features classifies the error with `UsageLimit.hit?` and `/Failed to parse Claude response/`; a todo feature with `resets_at` is `:paused`. `#title` host from `project.design_app_url`; resync from `since_setup.created_at` as `"%b %-d"`.

- [ ] **Step 4: Run them to see them pass** (same commands; Expected: PASS)

- [ ] **Step 5: Commit** — `feat: an import keeps its kind, its queue and who has seen it`

### Task 2: The Imports pages and their line

**Files:**
- Create: `app/views/workshop/designs_module/_imports.html.erb`, `app/views/workshop/design_imports/_import.html.erb`, `_card.html.erb`, `_progress.html.erb`, `app/helpers/design_imports_helper.rb`
- Modify: `app/controllers/workshop/designs_module_controller.rb` (TABS + "imports"; `@imports`, `@import`, mark seen), `app/views/workshop/designs_module/show.html.erb`, `_list_panel.html.erb`, `app/controllers/workshop/design_setup_runs_controller.rb#show` (renders the import page while master is not ready; redirects to `tab: "imports", import:` once it is), `app/views/workshop/design_setup_runs/show.html.erb` (renders `_import`)
- Test: `test/controllers/workshop/design_imports_pages_test.rb`

**Interfaces:**
- Consumes: Task 1's model methods.
- Produces: `workshop_designs_overview_path(tab: "imports", import: id)` as the import page; helper `import_card_text(feature) -> String`, `import_line(project, user) -> { lit:, right: }`.

- [ ] **Step 1: Write the failing tests**: "the Imports line is lit after an import settles, until its page is opened"; "the line says N need you while cards wait, else the date of the last import"; "Imports lists every import newest first with what each built"; "an import's page explains each card" (`"The AI's answer could not be read."`, `"Claude's session limit ran out at 06:50 (it resets at 08:00)."`, `"Waiting for you"` with the question); "Built lists each finished feature with its notes"; "someone without configuration sees the page but no actions"; "the setup page shows a first import that is still running"; "a stopped import shows why, with Retry".
- [ ] **Step 2: Run to fail** — `PARALLEL_WORKERS=1 bin/rails test test/controllers/workshop/design_imports_pages_test.rb` → FAIL (no imports tab).
- [ ] **Step 3: Implement** the partials after `docs/superpowers/specs/2026-11-04-designs-imports/import-page.html`, `imports-link.html` and `review-card.html` in the app's clar classes; the progress block is the current setup page's markup moved into `_progress` (steps while the import runs; the running feature's screens during a follow-up); the page polls with `designs-refresh` while busy.
- [ ] **Step 4: Run to pass**, then the existing `design_setup_runs_controller_test.rb` and `designs_module_controller_test.rb`.
- [ ] **Step 5: Commit** — `feat: every Designs import has a page that stays, and a line that lights`

### Task 3: Retry, Not needed, and each feature landing on master

**Files:**
- Create: `app/controllers/workshop/design_import_features_controller.rb`, `app/controllers/workshop/design_imports_controller.rb`, `app/services/designs/import_landing.rb`
- Modify: `config/routes.rb`, `app/jobs/designs/setup_run_job.rb`, `app/jobs/designs/resume_setups_job.rb`, `app/services/designs/subject.rb` (SetupSubject: setup from `session.design_setup`, branch from the running feature's `branch`), `app/services/designs/feature_brief.rb`, `app/services/designs/branch_names.rb`
- Test: `test/jobs/designs/import_follow_up_test.rb`, `test/controllers/workshop/design_import_actions_test.rb`

**Interfaces:**
- Routes: `resources :design_imports, only: :create, path: "designs/imports"` with member `post :retry_all, :add_feature` and nested `resources :features, only: [], controller: "design_import_features"` with member `post :retry, :reply, :set_aside, :accept, :reject, :revise`.
- Produces: `Designs::BranchNames.import(feature) -> "wip/import-<setup_id>-<key>"`; `Designs::ImportLanding.new(feature).land!(accepted: false) -> DesignMerge | nil` raising `Designs::ImportLanding::NeedsReview` (Task 7) and `Designs::Repo::Conflict`; `DesignSetup#start_work!` (enqueues the run job); `SetupRunJob#follow_up(setup)`.

- [ ] **Step 1: Write the failing tests**: "a retried feature is built on its own branch and lands on master as an import merge" (merge how "import", title the feature's name, master has the file, branch gone here and on origin); "Retry all queues every feature that needs you, once"; "a follow-up a deploy cut off is picked up again"; "a feature that collides with master couldn't land, and says why"; "the import settles once its last queued feature is done"; "only one import unit runs at a time on the server" (`SetupRunJob` limits concurrency under one key); controller: "Retry queues the feature and starts the work", "Tell the AI something first… goes with the retry", "Not needed sets the card aside", "someone without configuration cannot retry".
- [ ] **Step 2: Run to fail.**
- [ ] **Step 3: Implement.** A finished import with todo features runs them in `queued_at` order, one per unit: a fresh feature gets a new branch off master (an old one of that name goes, here and on origin); one that goes on keeps its branch. The request is `FeatureBrief.for(feature)` plus "## Before you start" (words) or "## You asked / They replied" (reply). Done → `ImportLanding#land!`: merge into master as "Import: <name>", push master with the branch's deletion atomically (master put back if the push fails), record the merge, remove the worktree and branch, publish master. `stalled` covers finished imports with pending features. `limits_concurrency to: 1, key: ->(*) { "designs-import" }, duration: 3.hours`.
- [ ] **Step 4: Run to pass**, then `test/jobs/designs/setup_run_job_test.rb`, `resume_setups_job_test.rb`, `test/services/designs/subject_test.rb`.
- [ ] **Step 5: Commit** — `feat: a feature of an import can be retried or set aside, and lands on master by itself`

### Task 4: Session limit and unreadable answers

**Files:**
- Modify: `app/jobs/designs/setup_run_job.rb`, `app/models/design_setup.rb` (`stalled` skips a paused run), `app/views/workshop/design_imports/_progress.html.erb`
- Test: `test/jobs/designs/import_limits_test.rb`

**Interfaces:**
- Produces: `Designs::SetupRunJob::Paused` (carries `until`); `DesignSetup#paused? -> Boolean`.

- [ ] **Step 1: Write the failing tests**: "a session limit pauses the run until it resets, then goes on with that feature" (feature back to todo with `resets_at`, `paused_until` set, the job enqueued for then, status still active); "a limit in the map step pauses instead of failing the run"; "a paused run is not taken for stalled"; "an unreadable answer is tried twice more before the feature couldn't finish" (three turns, attempts 2, status failed); "the page says the run is paused until the limit resets".
- [ ] **Step 2: Run to fail.** - [ ] **Step 3: Implement** (release the unit with its deadline at `paused_until + UNIT_GRACE`; `perform_later` with `wait_until: paused_until`). - [ ] **Step 4: Run to pass**, then the Task 3 files. - [ ] **Step 5: Commit** — `feat: an import waits out Claude's session limit and retries an answer it could not read`

### Task 5: Blockers and Send and continue

**Files:**
- Modify: `app/services/designs/turn_output.rb` (`blocked`, `comes_in`, `kept`, `replaced`), `app/jobs/designs/turn_job.rb#post_reply`, `app/models/chat_message.rb` (KINDS + `blocked comes_in kept replaced`), `app/services/designs/subject.rb` (SetupSubject feature protocol note), `app/jobs/designs/setup_run_job.rb`, `app/services/designs/repo.rb` (`fast_forward!`/`reset_branch!` as needed)
- Test: `test/services/designs/turn_output_test.rb`, `test/jobs/designs/import_blockers_test.rb`

**Interfaces:**
- Produces: `Designs::TurnOutput::Result#blocked -> String | nil`, `#comes_in`, `#kept`, `#replaced -> Array<String>`; feature `waiting` with `question`.

- [ ] **Step 1: Write the failing tests**: "a blocked block is the turn's question and stays out of the summary"; "comes-in, kept and replaced blocks are read in order"; "a feature the AI is blocked on waits with its question, and the run goes on"; "in the first import its partial work moves to its own branch, off wip/setup"; "a reply goes on from that branch with the question and the reply"; controller "Send and continue queues the reply".
- [ ] **Step 2–4** as above (run `turn_output_test.rb`, `turn_job_test.rb`, the new job file).
- [ ] **Step 5: Commit** — `feat: the AI can wait for an answer on one feature while the import goes on`

### Task 6: Missing feature? Add

**Files:** Modify `app/controllers/workshop/design_imports_controller.rb#add_feature`, `app/services/designs/feature_brief.rb`, `_import.html.erb`. Test: `test/controllers/workshop/design_import_actions_test.rb`, `test/jobs/designs/import_follow_up_test.rb`.

- [ ] **Step 1: Write the failing tests**: "Add makes a feature from the description and builds it like any other" (source "added", contexts as ticked, brief is the description, request says it is not on the map yet); "an empty description is refused".
- [ ] **Step 2–4.** - [ ] **Step 5: Commit** — `feat: a feature the map missed can be added from the import's page`

### Task 7: What comes in, accepted or rejected

**Files:**
- Create: `app/services/designs/thread_work.rb`
- Modify: `app/services/designs/repo.rb` (`diff_hunks(from, to)`, `blame_commits(ref, path, ranges)`, `commit_subject(sha)`, `merged_commits(merge_sha)`), `app/services/designs/import_landing.rb`, `app/jobs/designs/setup_run_job.rb`, `app/controllers/workshop/design_import_features_controller.rb` (`accept`, `reject`, `revise`), `app/services/designs/feature_brief.rb` (threads' work on master listed for follow-ups)
- Test: `test/services/designs/thread_work_test.rb`, `test/jobs/designs/import_reviews_test.rb`

**Interfaces:**
- Produces: `Designs::ThreadWork.new(repo, project).touched(base:, head:) -> Array<{ path: String, merge: DesignMerge | nil }>`; a commit is the import's own when its subject starts with `"setup: "` or is `Designs::InitializeRepoJob::COMMIT_MESSAGE`; any other commit is protected (a thread's, or one nobody can place). Feature `review` = `{ "comes_in", "kept", "replaced", "threads", "paths" }`.

- [ ] **Step 1: Write the failing tests**: "lines a thread put on master are its work"; "lines an import made are not"; "a line added beside a thread's does not change it"; "a commit nobody can place counts as a thread's"; "an update that changes a thread's lines waits for review instead of landing"; "Accept lands it"; "Reject keeps master as it is and sets the card aside"; "Tell the AI something first… goes on from the proposal's branch"; "Accept after master moved the same lines brings the proposal up to date first"; "the review card lists what comes in, what is kept and what is replaced".
- [ ] **Step 2–4.** - [ ] **Step 5: Commit** — `feat: an import never replaces a thread's work on master without Accept`

### Task 8: Resync from the app

**Files:**
- Create: `app/services/designs/app_changes.rb`
- Modify: `app/services/designs/app_repos.rb` (each row gets `"sha"`), `app/jobs/designs/setup_run_job.rb` (resync steps `read_repos sign_in find_changes features finish`), `app/models/design_setup.rb` (steps by kind), `app/services/designs/setup_prompts.rb` (phase "resync"), `app/services/designs/subject.rb` (resync tools and readable diff folder), `lib/designs_crawler/browser.mjs` (`save_features` takes `key` and `changes`), `app/controllers/workshop/design_imports_controller.rb#create`, `app/controllers/workshop/designs_module_controller.rb` and `base_controller.rb` (first imports only redirect and announce)
- Test: `test/services/designs/app_repos_test.rb`, `test/services/designs/app_changes_test.rb`, `test/jobs/designs/import_resync_test.rb`, `test/controllers/workshop/design_import_actions_test.rb`

**Interfaces:**
- Produces: `Designs::AppChanges.new(setup).fetch! -> [{ "repo", "branch", "from", "to", "path" }]`, the diff files under `setup.run_dir.join("changes")`; `DesignSetup#since_setup`; `Project#design_feature_map -> Array<DesignSetupFeature>` (the latest row per key).

- [ ] **Step 1: Write the failing tests**: "each repository read records its commit"; "the changes since the last import are written for the AI"; "an import that recorded no commits is taken at the time it read the repositories"; "a resync finds the changed and new features, builds each on its own branch and lands each on master"; "a resync that finds nothing changed finishes with nothing to build"; "a newer resync replaces a proposal still waiting for the same feature"; "New import starts a resync from the last import"; "a new import is refused while one runs".
- [ ] **Step 2–4.** - [ ] **Step 5: Commit** — `feat: a new import brings what developers built since the last one`

### Task 9: The server's thread limit

**Files:** Modify `lib/designs_crawler/browser_lib.mjs` (`CHROMIUM_ARGS`), `browser.mjs`, `sign_in.mjs`; Create `app/jobs/concerns/waits_for_design_import.rb`; Modify the six Claude jobs (`auto_estimate_job`, `alert_rule_run_job`, `pr_review_job`, `bug_attribution_job`, `project_features_scan_job`, `backfill_delivered_estimates_job`). Test: `lib/designs_crawler/test/browser_lib.test.mjs`, `test/jobs/waits_for_design_import_test.rb`.

- [ ] **Step 1: Write the failing tests**: "Chromium starts with one renderer and no GPU process"; "an AI job waits while an import unit runs and another AI job is running"; "it runs at once when no import runs".
- [ ] **Step 2–4**, then count the browser's threads on the server once (`/proc/<pid>/task`). - [ ] **Step 5: Commit** — `fix: an import's browser leaves room for the server's other work`

### Task 10: The notice, and shipping

- [ ] "Designs ready" is announced for first imports only, and its toast leads to the import's page (test in `design_imports_pages_test.rb`).
- [ ] Merge into production, push origin and kacper, deploy after a quiet tick, mirror main; on the server, check the Flosis import page renders its five cards (read-only).
