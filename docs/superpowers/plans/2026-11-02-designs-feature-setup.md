# Designs setup, feature by feature — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Designs v2's three-turn setup run with an unattended, resumable run that maps the app's features, then builds and browser-checks them one by one on the client's test environment, with the progress screen Kacper approved.

**Architecture:** `Designs::SetupRunJob` runs one unit per execution (a step, or one feature) and enqueues the next; each unit claims the run with a deadline, and `Designs::ResumeSetupsJob` (every 10 minutes) restarts a run whose unit outlived its deadline. Claude's setup turns keep running through `Designs::TurnJob`, now given a browser: a Node MCP server (`lib/designs_crawler/browser.mjs`, Playwright) with open/click/fill_form/screenshot/design/compare/check_design/progress/save_features tools, signed in from storage states that `Designs::SignIn` makes beforehand, so passwords never reach the model. The feature map lives in a new `design_setup_features` table.

**Tech Stack:** Rails 8.1, Ruby 3.4.1, Minitest 6, Solid Queue, Node 20, Playwright 1.54.2, `@modelcontextprotocol/sdk` 1.32.1, `zod` 4.6.7, Claude CLI (`--mcp-config --strict-mcp-config --restricted`).

**Spec:** `docs/superpowers/specs/2026-11-02-designs-feature-setup-design.md` (mockup beside it: `2026-11-02-designs-feature-setup/setup-progress.html`).

## Global Constraints

- Production is MariaDB 10.11: every JSON column is declared `attribute :name, :json` in its model, and added to `test/models/designs_json_columns_test.rb`.
- Tests: Minitest 6 has no `minitest/mock`; stand-ins are class-level seams (`attr_writer`, reset to nil in teardown). Run one test file at a time with `PARALLEL_WORKERS=1 bin/rails test <file>`; never two test processes at once; never touch `gold_development`; never run the real Claude CLI.
- Commits carry no `Co-Authored-By` or Claude trailer.
- Node packages are pinned exactly in `lib/designs_crawler/package.json`: `playwright` 1.54.2, `@modelcontextprotocol/sdk` 1.32.1, `zod` 4.6.7.
- Test-account passwords reach Node only on stdin, never argv, env, logs, files, the browser config or the model. Storage states are 0600 files in a 0700 folder.
- The leak guard is unchanged: setup turns write only `design-system/`, `components/`, `designs/`, `inspirations/`.
- The browser never navigates off the test environment's origin, never clicks a sign-out control, and `fill_form` never fills a password field and types addresses only `@example.test`.
- Bounds (runaway protection, not cost saving): a setup turn's timeout is `DESIGNS_SETUP_TIMEOUT_SECONDS` (default 7200) and budget `DESIGNS_SETUP_BUDGET_USD` (default 60).
- Copy, verbatim from the approved mockup: lead "This takes several hours: the features are built one by one, and each is checked against the app before the next one starts. You can leave this page and keep working. We’ll notify you when master is ready."; steps "Reading <repos>", "Signing in as <contexts>", "Mapping features: <N> found" (before: "Mapping features"), "Design system: tokens, fonts and icons from <UI> <version>", "Building features one by one: <done> of <N> done", "Committing to <repo> @ master"; cards "Notes for you" with "<N> · nothing is blocked", and "Features" with "<d> done · <r> in progress · <t> to do"; pills "Matches the app", "Done · 1 note" / "Done · <n> notes", "Building", "Checking against the app", "Up next", "To do", "Couldn't finish".

## Review Focus

1. A deploy kills the worker mid-feature: the re-delivered job (same `job_id`) takes the unit over at once, a different job finds the unit claimed and does nothing, and the watchdog restarts the run after the deadline, from that feature. Tests in Task 6.
2. One context cannot sign in (wrong password, or a session that expires during a 10-hour run): every feature signs in afresh, a failed context becomes a run note and the others carry on; only "none signed in" stops the run. Tests in Tasks 4 and 6.
3. The map names two features alike, or one whose name slugs to nothing: keys stay unique (`timesheet`, `timesheet-2`, `feature-3`) and positions dense from 1. Test in Task 1.
4. `fill_form` on a profile or change-password form: password fields stay empty, every typed e-mail is `@example.test`. Test in Task 3.
5. A click that leaves the origin (a link, a redirect after submit, a `target=_blank` link): the page goes back and the tool says it is not allowed; a "Sign out"/"Log out" control is refused before clicking. Test in Task 3.

---

### Task 1: The run's data — features, notes and units

**Files:**
- Create: `db/migrate/20261102120000_add_feature_setup.rb`, `app/models/design_setup_feature.rb`, `test/models/design_setup_feature_test.rb`
- Modify: `app/models/design_setup.rb`, `test/models/design_setup_test.rb` (create if missing), `test/models/designs_json_columns_test.rb`

**Interfaces:**
- Produces: table `design_setup_features` (`design_setup_id` FK not null, `position` int not null, `key` string not null, `name` string not null, `contexts` json, `screens` json, `brief` text, `status` string not null default "todo", `stage` string, `notes` json, `components_new` int default 0 not null, `components_reused` int default 0 not null, `design_turn_id` FK nullable on_delete nullify, `started_at`, `finished_at`, `error` text, timestamps; unique index `[design_setup_id, position]` and `[design_setup_id, key]`). Columns on `design_setups`: `notes` json, `unit_job_id` string, `unit_deadline_at` datetime.
- Produces: `DesignSetupFeature` — `STATUSES = %w[todo running done failed]`, `STAGES = %w[building checking]`; json attributes `contexts`, `screens`, `notes` default `[]`; `#label(up_next: false)` → the pill text; `#duration` (seconds or nil); `.key_for(name, taken)` → unique slug.
- Produces: `DesignSetup` — `PHASES = %w[map design_system feature]`, `STEPS = %i[read_repos sign_in map_features design_system features commit]`, `STEP_MINUTES = [10, 2, 20, 30, nil, 3]`, `FEATURE_MINUTES = 30`, `GUESSED_FEATURES = 15`; `has_many :features` (ordered by position, dependent destroy); `attribute :notes, :json, default: []`; `#steps` → `[[label, minutes]]`; `#percent`; `#minutes_left`; `#time_left` ("About 6 h left", "About 40 min left"); `#run_dir` → `Pathname(project.designs_dir).join("design-runs", id.to_s)`; `#note!(label, text)`; `#claim_unit!(job_id, limit:)` → Boolean; `#release_unit!`; `scope :stalled`; `#add_features!(rows)` (rows: `{ "name", "contexts", "screens", "brief", "notes" }`) → creates features with dense positions and unique keys.
- Removes: `DesignSetup::CRAWL_LIMIT`, `#crawling?`, `.stale_after`, `.fail_stale!`, `#next_phase!`.

- [ ] **Step 1: Write the failing tests**
  - `design_setup_feature_test.rb`: "label follows status and notes" — done without notes → "Matches the app"; done with 1 note → "Done · 1 note"; 2 notes → "Done · 2 notes"; running/building → "Building"; running/checking → "Checking against the app"; todo with `up_next: true` → "Up next", else "To do"; failed → "Couldn't finish". "keys stay unique": `key_for("Timesheet", %w[timesheet])` → "timesheet-2"; `key_for("!!!", [])` → "feature".
  - `design_setup_test.rb`: "steps before the map" → labels `["Reading acme/app @ production", "Signing in as Admin, Member", "Mapping features", "Design system: tokens, fonts and icons from Tailwind 4", "Building features one by one", "Committing to acme/designs @ master"]` and minutes `[10, 2, 20, 30, 450, 3]`; "steps after the map" with 3 features (1 done) → "Mapping features: 3 found", "Building features one by one: 1 of 3 done", features minutes 60; "time left" → "About 6 h left" for 360, "About 40 min left" for 40; "a unit is claimed once": `claim_unit!("a", limit: 1.hour)` true, `claim_unit!("b", …)` false, `claim_unit!("a", …)` true (same job), after `travel 2.hours` `claim_unit!("b", …)` true; "stalled" lists an active run whose deadline passed and not a finished one; "add_features! keeps positions dense and keys unique" with names `["Timesheet", "Timesheet", "!!!"]` → keys `timesheet, timesheet-2, feature-3`… (use `feature` then `feature-2` rule consistently: `key_for` appends `-<n>` from 2), positions `[1, 2, 3]`.
  - `designs_json_columns_test.rb`: add `DesignSetupFeature` (`contexts`, `screens`, `notes`) and `DesignSetup` (`notes`).

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/design_setup_feature_test.rb` (then each other file)
Expected: FAIL — uninitialized constant DesignSetupFeature / missing table.

- [ ] **Step 3: Write the migration and the models.** `repos` in `#steps` reads `project.design_app_repos` rows' `"repo"` (as today), the contexts `project.design_setup_roles.map(&:name)`, the UI name from `Workshop::DesignSetupRunsController::UI_SYSTEMS` (a `[key, label, version]` list — look the label up by key). Feature minutes: `FEATURE_MINUTES ×` features not finished (or `GUESSED_FEATURES` before the map). `claim_unit!` runs under `with_lock`.

- [ ] **Step 4: Migrate the test database and run the tests**

Run: `RAILS_ENV=test bin/rails db:migrate` then each file as in Step 2.
Expected: PASS.

- [ ] **Step 5: Commit** — `feat: a setup run's features, notes and units`

### Task 2: The prompts of a feature-by-feature run

**Files:**
- Modify: `app/services/designs/setup_prompts.rb`, `test/services/designs/setup_prompts_test.rb`, `test/db/update_setup_prompts_for_v2_test.rb` (if it reads SEEDS by phase)
- Create: `db/migrate/20261102120100_seed_feature_setup_prompts.rb`, `test/db/seed_feature_setup_prompts_test.rb`, `test/fixtures/files/setup-design-system_v2.txt`

**Interfaces:**
- Produces: `Designs::SetupPrompts::SEEDS` keyed `"map"` (key `setup-map`, name "Setup: feature map"), `"design_system"` (key `setup-design-system`, rewritten), `"feature"` (key `setup-feature`, name "Setup: one feature"). `Designs::Library.compose_setup(phase)` is unchanged and reads these.
- Produces: migration `SeedFeatureSetupPrompts`: creates `setup-map` and `setup-feature` entries (kind `base_prompt`, version 1 = seed body) when missing; gives `setup-design-system` a new version with the v3 body only when its current body's SHA-256 equals v2's (`V2_DIGEST`, the digest of the body this task replaces, kept in the fixture file).

Prompt content (each under twelve words of overlap with the template README/index, as the existing guard test checks):
- `setup-map`: read routes, controllers, menus and views; use the app with the browser tools as each context; a feature is an area a person would name (its lists, details, forms and flows); the app shell and sign-in come first, then features in an order where shared pieces appear early; save the map with `save_features` (name, contexts by slug, screens, a brief naming flows and code paths, notes for what the test environment lacks); write no files.
- `setup-design-system`: as today, but read computed styles in the browser instead of a crawl bundle; keep the lockfile check.
- `setup-feature`: the browser is signed in as each context; create the records the feature needs, change and delete only what you created; never leave the environment, never sign out, never change the test accounts; use `fill_form` rather than typing field by field; write every screen of every context the feature has in `designs/<context>/`, as the app shows it, with its flows (forms lead on, modals, tabs, states); reuse components, add missing ones with README and preview; call `progress` as each screen is built and checked; check each screen with `compare` and `check_design`, fix, check again, at most three rounds; build from the code what the environment cannot show and say so; a `<missing>` block is one sentence, only for something that makes the design differ from the app or left unchecked.

- [ ] **Step 1: Write the failing tests** — `setup_prompts_test.rb`: "a run has three phases" (`SEEDS.keys == %w[map design_system feature]`, keys `setup-map setup-design-system setup-feature`); "the map is saved with its tool" (`setup-map` body includes `save_features`); "a feature checks itself" (body includes `compare`, `check_design`, `progress`, `fill_form`, "only what you created"); "the design system still checks the stack" (lockfile); the existing twelve-word guard over all seeds. `seed_feature_setup_prompts_test.rb`: "seeds the new phases", "updates an untouched design-system prompt", "leaves an edited one".
- [ ] **Step 2: Run them to verify they fail** — Expected: FAIL on the missing keys.
- [ ] **Step 3: Save v2's design-system body to the fixture first** (`Designs::SetupPrompts::SEEDS["design_system"][:body].strip` before the edit), then rewrite SEEDS and write the migration (it defines its own `Entry`/`Version` table classes, as `UpdateSetupPromptsForV2` does).
- [ ] **Step 4: Run the tests** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: the setup's map, design-system and feature prompts`

### Task 3: The browser tools (Node)

**Files:**
- Create: `lib/designs_crawler/login.mjs`, `lib/designs_crawler/sign_in.mjs`, `lib/designs_crawler/browser_lib.mjs`, `lib/designs_crawler/browser.mjs`, `lib/designs_crawler/test/browser_lib.test.mjs`, `lib/designs_crawler/test/browser.test.mjs`, `test/lib/designs_browser_test.rb`
- Modify: `lib/designs_crawler/package.json`, `lib/designs_crawler/package-lock.json`, `lib/capistrano/tasks/designs_crawler.rake`
- Delete: `lib/designs_crawler/crawl.mjs`

**Interfaces:**
- `login.mjs` exports `logIn(page, role)` (today's crawl.mjs logic) and `safe(error, secrets)`.
- `sign_in.mjs <outDir>`, stdin `{ "roles": [{ "slug", "name", "loginUrl", "username", "password" }] }`: saves `<outDir>/<slug>.json` storage states (mode 0600), prints `{ "roles": [{ "slug", "ok", "error" }] }`; exit 0 when any signed in, 2 when none, 1 otherwise. Errors are masked.
- `browser.mjs`: an MCP stdio server named `flosis_browser`, reading `FLOSIS_BROWSER_CONFIG` → `{ "baseUrl", "contexts": [{ "slug", "name", "statePath" }], "worktree", "progressPath", "featuresPath", "featureKey", "viewport": { "width": 1440, "height": 900 } }`. Tools (inputs in parentheses):
  - `open(context, path)` → text page state: URL, title, numbered interactive elements (`[e12] button "Save"`, `[e13] link "Projects" → /projects`, `[e14] textbox "Name" required`) and a text excerpt (≤ 4,000 chars).
  - `click(context, ref)` → page state; refuses sign-out controls; a navigation off-origin (also a new tab) is undone and reported "Not allowed: that leaves the test environment."
  - `fill_form(context, ref?, values?, mode = "valid" | "invalid", submit = false)` → the fields filled (`Label = value`) and the page state. Values in `values` win, matched by label, name or id, case-insensitive. Never fills `type=password`. Invalid mode empties required fields, breaks formats and sets `noValidate` before a submit.
  - `screenshot(context, full_page = false)` → an image.
  - `design(path)` → the page state of `designs/…` served from the worktree by a 127.0.0.1 static server, plus console errors.
  - `compare(context, app_path, design_path)` → two images (the app's, the design's) at the same viewport.
  - `check_design(path)` → a report: console errors, relative links whose file is missing in the worktree, includes the runtime marked missing.
  - `progress(screen, status = "building" | "checking" | "done")` → writes `{ "feature": featureKey, "screens": { screen: status } }` to `progressPath`.
  - `save_features(features: [{ name, contexts, screens, brief, notes }])` (only when `featuresPath` is set) → writes the list to `featuresPath`.
- `browser_lib.mjs` exports the pure parts: `sameOrigin(base, url)`, `signOut(text, href)` (`/log\s*-?\s*out|sign\s*-?\s*out|logout|signout/i`), `valueFor(field, mode)` (field: `{ type, name, label, required, min, max, minLength, maxLength, pattern, options }`).
- Rake task uploads every `*.mjs` file and `package*.json`, runs `npm ci --omit=dev` (or `npm install` without a lock) and `npx playwright install chromium`.

- [ ] **Step 1: Write the failing Node tests.** `browser_lib.test.mjs`: "same origin only" (`https://a.test/x` vs `https://a.test/y` true, `https://b.test` false, `//b.test/x` false); "sign-out is refused" ("Log out", "Sign out", `/session` with `data-turbo-method=delete`? — the href pattern `/logout`); "valid values" (email → ends `@example.test`, number within min/max, select → first non-empty option, date ISO, required checkbox checked); "invalid values" (required → "", email → no `@`); "password is never filled" (`valueFor({ type: "password" }, "valid") === null`). `browser.test.mjs` (skips when Chromium cannot launch): starts a local HTTP server with a login page, a page with a form (name, email, password, select, required), a "Sign out" link, an off-origin link and a `target=_blank` off-origin link; runs `sign_in.mjs` and then `browser.mjs` through the SDK's stdio client; asserts: sign-in writes a 0600 state; `open` lists the form's fields with refs; `fill_form` fills name/email/select, leaves password empty, email `@example.test`; `click` on "Sign out" is refused; `click` on both off-origin links answers "Not allowed" and the page stays on the origin; `progress` and `save_features` write their files; `design` serves a worktree file and reports a console error; `check_design` reports a missing link target.
- [ ] **Step 2: Run them to verify they fail**

Run: `cd lib/designs_crawler && node --test test/`
Expected: FAIL — modules not found.

- [ ] **Step 3: Install the pinned dependencies and implement** `login.mjs`, `sign_in.mjs`, `browser_lib.mjs`, `browser.mjs`; delete `crawl.mjs`; update the rake task.
- [ ] **Step 4: Run the Node tests** — Expected: PASS. Then write `test/lib/designs_browser_test.rb` ("the browser tools pass their own tests": runs `node --test test/` in the folder, skips without Node) and run it: PASS.
- [ ] **Step 5: Commit** — `feat: the setup's browser tools (MCP) and sign-in`

### Task 4: Reading the app repositories and signing in, from Rails

**Files:**
- Create: `app/services/designs/app_repos.rb`, `app/services/designs/sign_in.rb`, `test/services/designs/app_repos_test.rb`, `test/services/designs/sign_in_test.rb`
- Delete: `app/jobs/designs/crawl_job.rb`, `test/jobs/designs/crawl_job_test.rb`

**Interfaces:**
- Produces: `Designs::AppRepos.new(setup)` — `#fetch!` → `[{ "role", "repo", "branch", "dir" }]` for each row of `project.design_app_repos` (`"owner/name@branch"`), cloned `--depth 1` (with `--branch` when named) into `setup.run_dir.join("apps", "<n>-<name>")` by `GitRunner.run!` with `ProjectCredentials.new(project).github_token`, then sealed read-only (files 0444, folders 0555). A repo that fails becomes `setup.note!("Reading the repositories", …)`; none cloned raises `Designs::AppRepos::Failure`. `#dirs` → the folders cloned. Seam: `Designs::AppRepos.url_for = ->(name) { … }` (default `"https://github.com/#{name}.git"`).
- Produces: `Designs::SignIn.new(setup)` — `#call` → `{ slug => ok }`; runs `node sign_in.mjs <run_dir/auth>` from `Designs::SignIn.crawler_dir` (`ENV["DESIGNS_CRAWLER_DIR"]` or `lib/designs_crawler`) with the roles on stdin, env only `PLAYWRIGHT_BROWSERS_PATH`/`TMPDIR`; a failed context → `setup.note!("Signing in", "<Name> could not sign in: <error>")` (once per run and error); none → `Designs::SignIn::Failure`. `Designs::SignIn.slug(role)` → `<position+1>-<parameterized name>`. Seam: `Designs::SignIn.runner` (as CrawlJob's, returns `[stdout, stderr, status]`).

- [ ] **Step 1: Write the failing tests.** `app_repos_test.rb`: "clones each repository at its branch" (a local bare repo with `main` and `production`, row `acme/app@production` → the clone has production's file, files read-only); "the default branch without @"; "a repository that fails is a note, the rest go on"; "none cloned stops the run". `sign_in_test.rb`: "passwords go on stdin only" (the runner gets argv without the password and env with only the two keys; stdin JSON has it); "states are private" (auth folder 0700 after the runner wrote files); "a failed context is a note"; "nobody signed in stops the run".
- [ ] **Step 2: Run them to verify they fail** — Expected: FAIL, constants missing.
- [ ] **Step 3: Implement both services; delete CrawlJob and its test.**
- [ ] **Step 4: Run the two test files** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: the setup reads the app repositories and signs in without the model`

### Task 5: Setup turns with a browser

**Files:**
- Modify: `app/jobs/designs/turn_job.rb`, `app/services/designs/subject.rb`, `app/models/design_turn.rb`, `test/jobs/designs/turn_job_test.rb`, `test/services/designs/subject_test.rb`, `test/models/design_turn_test.rb`

**Interfaces:**
- Consumes: `DesignSetup#run_dir`, `#features`, `Designs::AppRepos#dirs` (reads `run_dir/apps/*`), `Designs::SignIn.slug`, `Designs::SignIn.crawler_dir`.
- Produces: every subject answers `tools`, `with_mcp(worktree) { |path_or_nil| }`, `timeout`, `budget_usd`, `app_copy?`. Thread and task subjects: `TurnJob::TOOLS`, yields nil, `DesignTurn.turn_timeout`, `DesignTurn.turn_budget_usd`, true.
- Produces: `SetupSubject` — `tools` = `TOOLS + BROWSER_TOOLS` (`mcp__flosis_browser__open click fill_form screenshot design compare check_design progress`, plus `save_features` in the map phase); `with_mcp` writes `run_dir/browser.json` (no password in it) and a temp `.mcp.json` `{ "mcpServers": { "flosis_browser": { "command": "node", "args": [<crawler_dir>/browser.mjs], "env": { "FLOSIS_BROWSER_CONFIG", "PLAYWRIGHT_BROWSERS_PATH", "TMPDIR" } } } }`, removed after the block; `add_dirs` = the cloned app folders + materials; `app_copy?` false; `timeout` `DesignTurn.setup_timeout`; `budget_usd` `DesignTurn.setup_budget_usd`; `turn_message(request)` = stack, app repositories, contexts (name and slug), request. `setup` is the run's latest active setup; `phase` drives `compose_setup`.
- Produces: `DesignTurn::KINDS` adds `"setup"`; `.setup_timeout` (`DESIGNS_SETUP_TIMEOUT_SECONDS`, default 7200), `.setup_budget_usd` (`DESIGNS_SETUP_BUDGET_USD`, default 60), `#stale?` and `.fail_stale!` use `setup_timeout + 5.minutes` for setup turns.
- Removes: TurnJob's crawl waiting (`WAITING_FOR_CRAWL`, `CRAWL_POLL`, `waiting_for_crawl?`, `wait_for_crawl`), every subject's `crawling?`.

- [ ] **Step 1: Write the failing tests.** `turn_job_test.rb`: "a setup turn gets the browser" (the factory receives `mcp_config:` naming a file that exists during the run and lists `flosis_browser` with `FLOSIS_BROWSER_CONFIG`; `allowed_tools` include `mcp__flosis_browser__compare`; `timeout: 7200`; no app copy in `add_dirs`); "the browser config holds no password" (read the config file during the run); "a thread turn has no browser" (`mcp_config: nil`, `allowed_tools == TOOLS`). `design_turn_test.rb`: "a long setup turn is not stale" (a setup turn running 30 minutes is not failed by `fail_stale!`, a design turn running 30 minutes is). `subject_test.rb`: "the map phase may save features" (`save_features` tool only in the map phase); "a setup turn reads the cloned repositories".
- [ ] **Step 2: Run them to verify they fail.**
- [ ] **Step 3: Implement.** `ask_claude` passes `allowed_tools: subject.tools`, `mcp_config:` from `subject.with_mcp(worktree)`, `max_budget_usd: subject.budget_usd`, `timeout: subject.timeout`, and adds the app copy only when `subject.app_copy?`.
- [ ] **Step 4: Run the three files** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: setup turns run with a browser and longer bounds`

### Task 6: The run, unit by unit, and resuming it

**Files:**
- Modify: `app/jobs/designs/setup_run_job.rb`, `test/jobs/designs/setup_run_job_test.rb`, `app/controllers/workshop/design_setup_runs_controller.rb`, `app/controllers/workshop/designs_module_controller.rb`, `app/services/designs/threads.rb`, `config/recurring.yml`
- Create: `app/jobs/designs/resume_setups_job.rb`, `app/services/designs/feature_brief.rb`, `app/services/designs/component_count.rb`, `test/jobs/designs/resume_setups_job_test.rb`, `test/services/designs/component_count_test.rb`

**Interfaces:**
- Consumes: Task 1's model API, Task 4's services, Task 5's setup turn.
- Produces: `Designs::SetupRunJob#perform(setup_id)` — returns unless active; returns unless `setup.claim_unit!(job_id, limit: UNIT_LIMIT)` (`DesignTurn.setup_timeout + 15.minutes`); runs `STEPS[setup.step]`; `release_unit!`; enqueues itself unless finished or failed. Seams: `.turn_runner`, `.sign_in` (`->(setup) { Designs::SignIn.new(setup).call }`), `.app_repos` (`->(setup) { Designs::AppRepos.new(setup).fetch! }`).
  - `map_features`: phase "map"; a setup turn (kind "setup") with `MAP_REQUEST`; reads `run_dir/features.json` into `add_features!`; none → `Failure`, "The map found no features.".
  - `features`: the first feature `todo` or `running`; none → next step. Signs in afresh; `running`/`building`, `started_at` kept when set; clears `run_dir/progress.json`; phase "feature"; a turn with `Designs::FeatureBrief.for(feature)`; after it: succeeded → `done`, `components_new`/`components_reused` from `Designs::ComponentCount.between(repo, from_sha, to_sha)`, notes from the turn's `missing` replies; failed → `failed`, `error`, note "Could not finish: <error>". One feature per execution.
  - `commit`: as today.
- Produces: `Designs::FeatureBrief.for(feature)` → the request text (feature name, contexts by name and slug, planned screens, brief, notes so far).
- Produces: `Designs::ComponentCount.between(repo, from, to)` → `{ new:, reused: }` (new: component folders at `to` not at `from`; reused: components included by screens changed in the range that existed at `from`).
- Produces: `Designs::ResumeSetupsJob` (queue `designs`): for each `DesignSetup.stalled`, fails its running turn as interrupted, `release_unit!`, enqueues `SetupRunJob`. `config/recurring.yml` production: `resume_design_setups: { class: Designs::ResumeSetupsJob, schedule: every 10 minutes }`.
- Removes: the callers of `DesignSetup.fail_stale!` (setup runs show, designs module show, `Designs::Threads`).

- [ ] **Step 1: Write the failing tests.** `setup_run_job_test.rb` (fake sign-in, fake repos, fake turns that commit and post replies; the job run repeatedly with `perform_now` until done, enqueued jobs drained): "the run maps the features, builds each and lands on master" (status approved, 6 steps, 3 features done, a DesignMerge "Initial import from staging"); "a feature whose turn fails is marked and the run goes on" (feature failed with a note, next done); "a re-delivered job takes its unit over, another one waits" (same `job_id` runs, other does nothing); "a context that cannot sign in is a note"; "no context signs in: the run stops with the reason"; "an empty map stops the run"; "a re-import stops short of master". `resume_setups_job_test.rb`: "a stalled run is resumed at its feature" (running feature's turn failed as interrupted, unit released, job enqueued). `component_count_test.rb`: "new and reused components".
- [ ] **Step 2: Run them to verify they fail.**
- [ ] **Step 3: Implement**, remove the `fail_stale!` callers, add the recurring entry.
- [ ] **Step 4: Run the four files, then the designs module and threads tests** (`test/controllers/workshop/designs_module_controller_test.rb`, `test/services/designs/threads_test.rb`) — Expected: PASS.
- [ ] **Step 5: Commit** — `feat: the setup runs feature by feature and resumes after a restart`

### Task 7: The progress screen and the form's copy

**Files:**
- Modify: `app/views/workshop/design_setup_runs/show.html.erb`, `app/views/workshop/design_setup_runs/new.html.erb`, `app/controllers/workshop/design_setup_runs_controller.rb`, `test/controllers/workshop/design_setup_runs_controller_test.rb`
- Create: `app/helpers/design_setup_runs_helper.rb`, `app/services/designs/run_progress.rb`

**Interfaces:**
- Consumes: `DesignSetup#steps/#percent/#time_left/#notes/#features`, `DesignSetupFeature#label`.
- Produces: `Designs::RunProgress.read(setup)` → `{ screen => status }` for the running feature (from `run_dir/progress.json`, `{}` when missing or for another feature).
- Produces: helper `setup_feature_sub(feature)` → "Admin, Member · 4 screens · 9 new components" / "· 3 new components, 6 reused" / "· 9 components reused" / for a feature not built "Admin · about 3 screens"; `setup_duration(seconds)` → "38 min" / "1 h 5 min"; `setup_notes(setup)` → `[[label, text]]` (run notes first, then each feature's as "HOLIDAYS · DONE", "… · IN PROGRESS", "… · UP NEXT", "… · TO DO").

- [ ] **Step 1: Write the failing tests** — `design_setup_runs_controller_test.rb`: "the progress screen shows the features" (a run with 3 features: done, done with a note, running with progress `{ "Pipeline" => "done", "Ready" => "checking" }`, plus one todo → the page has "Matches the app", "Done · 1 note", "Checking against the app", "Up next", "Features", "2 done · 1 in progress · 1 to do", the running feature's "Ready · checking"); "notes for you" ("Notes for you", "2 · nothing is blocked", "HOLIDAYS · DONE"); "the steps follow the run" ("Mapping features: 4 found", "Building features one by one: 2 of 4 done"); "the form speaks of the test environment" (new page has "Test environment and contexts" and "Several hours, in the background").
- [ ] **Step 2: Run it to verify it fails.**
- [ ] **Step 3: Implement** the view after the mockup with the app's `clar-` classes and tokens (as today's show view does), the helper and `RunProgress`; the form's third section reads "Test environment and contexts" / "The AI signs in as each context and uses the app on test data: it may create, change and delete what it needs. Use a test environment (staging, or a test workspace on production) and a test account per context."; its hint "Several hours, in the background. You can keep working."; the create toast "Building designs in the background · several hours".
- [ ] **Step 4: Run the controller test** — Expected: PASS. Then `bin/rails tailwindcss:build` and render the page once in the test log to check no missing classes.
- [ ] **Step 5: Commit** — `feat: the setup's progress screen, feature by feature`

---

## After the tasks

- Whole-suite sweep, file by file (`PARALLEL_WORKERS=1`), compared with the known date-dependent failures (reports_controller, holiday_request, workshop_report).
- Final whole-branch review by a fresh reviewer on the most capable model, one fix pass.
- Deploying needs Kacper's go-ahead. On the server, before the first run: `cap production setup:designs_crawler`, `.env` gets `DESIGNS_CRAWLER_DIR=<shared>/designs_crawler` and `PLAYWRIGHT_BROWSERS_PATH=$HOME/.cache/ms-playwright`, and a ten-second Chromium launch proves the browser runs on Hostido.
