# Workshop Designs v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace v1's per-task Designs screen with Kacper's Designs module: threads as branches from master, the canvas with View as / This branch / Master / Changes, merges by hand or on Done, the setup form with an unattended import, and the Designs permission.

**Architecture:** A thread is a `DesignThread` row, a `design/…` branch in the project's design repo and a `ChatSession` (purpose `designs_thread`). Turns keep v1's `Designs::TurnJob` through a new `ThreadSubject`. Designs stay static HTML + CSS published by `Designs::Publisher`. New services work out the screens of a ref, expand `<x-include>` as text and diff a branch against its base for Changes. The module is new Workshop controllers and views, styled as the rest of Clar, following `ClearBacklog-3.html`.

**Tech Stack:** Rails 8.1, Minitest + fixtures, Turbo/Stimulus, Tailwind v4 (`clar-` classes), Nokogiri, git CLI through `Designs::Repo`, Solid Queue (`designs` queue).

**Spec:** `docs/superpowers/specs/2026-11-02-workshop-designs-v2-design.md`; screens in `docs/superpowers/specs/2026-11-02-designs-v2/ClearBacklog-3.html` and the approved mockup `ClearBacklog-3-master-changed.html`.

## Global Constraints

- **Copy is verbatim** from the spec's "The screens, item by item". `<…>` is filled in. A deviation needs a `Ruling:` line in the ledger.
- **Branch names:**
  - `design/<KEY>-<slug>` for a thread started from a task;
  - `design/<slug>` otherwise;
  - the slug is the first four words, parameterized;
  - a task without a Jira issue uses `task-<id>`;
  - names never change.
- **Turns change only** `design-system/`, `components/`, `designs/` and `inspirations/`. `README.md`, `index.html` and `runtime/` are Flosis's.
- **No design-repo code runs on the server.** Expanding includes and diffing work on text and Nokogiri only.
- **Permissions:**
  - Designs (new) gates the module, the task strip and the pipeline badges.
  - Configuration gates the setup form, Edit setup and Re-import.
- **Previews stay** under `app.flosis.com/<org>/<project>/…`, behind grants, with the CSP sandbox from v1.
- **Stacks:** only HTML + CSS with Tailwind (v4) or Custom can be picked. Vue.js, React, Angular, Foundation, Bootstrap and Material are disabled and show "Soon".
- **Tests and environment:**
  - Run test files one at a time with `PARALLEL_WORKERS=1 bin/rails test <file>`; the pg gem segfaults on the full suite.
  - No real Claude CLI in tests.
  - Never touch `gold_development`, and never start a dev server.
- **Commits** carry no Claude trailers.

## Review Focus

1. **A thread whose branch moved on GitHub** under it, or a clone missing the branch. The person expects the thread to recover from origin, not a 500. Test in Task 4: Repo creates the branch from origin when the local clone lacks it.
2. **Two people press Merge on the same thread at once,** or Merge while a turn runs. The person expects one merge and a "busy" notice. Test in Task 7: a second merge raises Busy, and a merge while a turn is active is refused.
3. **A task with a thread is deleted, or moved out of the pipeline.** The person expects the thread to stay openable as "NO TASK". Test in Task 2: `task_id` is nullified, not destroyed.
4. **An include path with `..`, an absolute path, or a cycle.** The person expects a red "Missing component" marker in Changes, never a read outside the repo. Test in Task 3.
5. **Jira sync marks a task Done whose thread is behind master and conflicts.** The person expects no merge, and the thread to say why. Test in Task 8.

---

### Task 1: Designs permission

**Files:**
- Create: `db/migrate/20261102100000_add_designs_to_project_memberships.rb`
- Modify: `app/models/permission_preset.rb`, the Users tab and invite-modal views that list permission notes (`app/views/workshop/configuration/_users_tab.html.erb`, `_invite_modal.html.erb`, `_permission_legend.html.erb`)
- Test: `test/models/permission_preset_test.rb`, `test/controllers/workshop/configuration_controller_test.rb`

**Interfaces:**
- Produces: `can?(:designs)`. `PermissionPreset::PERMISSIONS` is `%i[automations tasks designs reporting pricing briefing_config configuration]`.

- [ ] **Step 1: Write the failing tests.**
  - `test "Product Owners and Administrators get Designs by default, Project Managers do not"` asserts the presets.
  - `test "the users tab offers a Designs switch with its default"` asserts the switch label "Designs" and the note "Product Owners and Administrators by default".
- [ ] **Step 2: Run them.** Expected: FAIL (no designs column).
- [ ] **Step 3: Implement.**
  - Migration: `add_column :project_memberships, :designs, :boolean, default: false, null: false`. Workspace admins with configuration get `true` in the migration, so today's admins keep seeing Designs.
  - In the preset, add LABELS `designs: "Designs"` and DESCRIPTIONS `designs: "Open Designs: the project's clickable designs, its threads and merges."`. Turn it on in the Product Owner and Administrator presets.
  - The note "Product Owners and Administrators by default" sits beside the switch wherever the Briefing Configuration note sits.
  - The defaults sentence becomes "Product Owner: those plus Designs and Briefing Configuration".
- [ ] **Step 4: Run** `PARALLEL_WORKERS=1 bin/rails test test/models/permission_preset_test.rb test/controllers/workshop/configuration_controller_test.rb`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: a Designs permission, on for Product Owners and Administrators`.

### Task 2: Threads, merges and the project's stack

**Files:**
- Create:
  - `db/migrate/20261102100100_create_design_threads.rb` and `20261102100200_create_design_merges.rb`;
  - `db/migrate/20261102100300_add_designs_v2_fields.rb`, which adds to projects: `designs_framework` (default "html"), `designs_framework_version`, `designs_ui_system` (default "tailwind"), `designs_ui_version` (default "4") and `design_app_repos` (json). It adds to chat_messages `data` (json), and to design_setups `step` (integer, default 0), `error` (text), `finished_at`, `pages` (integer) and `design_thread_id`;
  - `app/models/design_thread.rb`, `app/models/design_merge.rb`, `app/services/designs/thread_names.rb`.
- Modify: `app/models/project.rb` (`has_many :design_threads, :design_merges`), `app/models/task.rb` (`has_one :design_thread, dependent: :nullify`), `app/models/chat_session.rb` (PURPOSES + `designs_thread`).
- Test: `test/models/design_thread_test.rb`, `test/services/designs/thread_names_test.rb`.

**Interfaces:**
- **Produces, `DesignThread`:**
  - columns: `project_id`, `task_id` (unique where not null), `author_id`, `chat_session_id`, `title`, `branch` (unique per project, null until named), `status` ("open"/"merged"), `base_sha`, `merged_sha`, `merged_at`, `focus_context`, `focus_screen`, `described_text`, `described_version`;
  - scopes `open`, `merged`, plus `merged?` and `fresh?` (no branch yet).
- **Produces, `DesignMerge`:** `project_id`, `design_thread_id` (optional), `task_id` (optional), `user_id` (optional), `sha`, `title`, `branch`, `how` ("manual"/"auto"/"setup"), `screens` (json array of "context/screen"), `commits`, `summary`, `changes` (json array), `merged_at`. It also has `how_label`, which returns "Manual · <name>", "Auto · <KEY> moved to Done" or "Flosis AI · setup".
- **Produces, names:** `Designs::ThreadNames.branch_for(text:, task: nil) -> String` and `Designs::ThreadNames.key(task) -> String`.

- [ ] **Step 1: Write the failing tests.**
  - `branch_for(text: "Let recruiters move several candidates at once")` is `"design/let-recruiters-move-several"`.
  - With a task whose `external_reference` is "SP-1051", it is `"design/SP-1051-inline-validation-on-question"`.
  - A task without a Jira key gives `"design/task-<id>-…"`.
  - A second open thread for the same task is invalid.
  - Destroying the task nullifies `task_id`.
  - `DesignMerge#how_label` gives each of the three strings.
- [ ] **Step 2: Run.** Expected: FAIL (no tables).
- [ ] **Step 3: Implement** the migrations, models and names. A name that is taken gets a `-2` suffix.
- [ ] **Step 4: Run** both test files. Expected: PASS.
- [ ] **Step 5: Commit** `feat: design threads and merges`.

### Task 3: Screens, includes and changes

**Files:**
- Create: `app/services/designs/screens.rb`, `app/services/designs/includes.rb`, `app/services/designs/changes.rb`.
- Test: `test/services/designs/screens_test.rb`, `includes_test.rb`, `changes_test.rb`.

**Interfaces:**
- **Consumes:** a `reader`, a lambda `->(path) { String or nil }` that reads a file at a ref (`Repo#read_file(ref, path)`), and a `paths` list (`Repo#ls_files(ref, "designs/")`).
- **Produces, screens:** `Designs::Screens.new(paths:, reader:)` with:
  - `#contexts`, a list of `{ id:, name: }`, where the name is the humanized folder;
  - `#screens`, a list of `{ id:, context:, name:, path: }`, where the name is the `<title>`, falling back to the humanized file name;
  - `#find(context, id)` and `#as_json`, which the runtime reads.
- **Produces, includes:** `Designs::Includes.expand(html, reader:) -> String`. It mirrors `runtime/flosis.js`:
  - `{{name}}` placeholders take the escaped attribute;
  - the children replace `<slot>`;
  - at most 10 rounds;
  - a src that is empty, absolute, contains `..`, or is missing becomes `<div data-flosis-missing="<src>"></div>`.
- **Produces, changes:** `Designs::Changes.new(base:, head:)`, where each is a `Screens` plus a reader. It has:
  - `#changed`, a list of `{ context:, screen:, kind: "new"|"updated" }`;
  - `#marked_html(context, screen) -> String`, the head screen expanded, with `data-flosis-change="new|updated"` on the smallest differing elements.

- [ ] **Step 1: Write the failing tests.**
  - Screens: contexts come from folder names; the screen name is taken from `<title>`.
  - Includes: placeholders; slots; nested includes; a cycle stops after 10 rounds with the marker; `../secret` and `/etc/passwd` become the marker.
  - Changes: an added `<p>` is marked new; changed text in a `<button>` marks it updated; an unchanged screen is not listed; a screen absent from the base is `kind: "new"`; a component change marks every screen that includes it.
- [ ] **Step 2: Run.** Expected: FAIL (uninitialized constants).
- [ ] **Step 3: Implement.** Use Nokogiri::HTML5. Diff the children of `body` by an LCS over signatures (tag, id and class for elements; normalized text for text nodes):
  - an unmatched head element is "new";
  - a matched element whose attributes or own text differ is "updated";
  - a removed child marks its head parent "updated";
  - a node under an already marked ancestor is not marked.
- [ ] **Step 4: Run** the three files. Expected: PASS.
- [ ] **Step 5: Commit** `feat: screens of a ref, includes as text, changes against a base`.

### Task 4: Repo, publisher, guard and template for threads

**Files:**
- Modify:
  - `app/services/designs/repo.rb`: `ls_files(ref, prefix) -> [String]`, `merge_base(a, b) -> sha`, `merges_between(from_sha, to_sha) -> [sha]` (first-parent merges on master), and `branch!(name, from: sha)`, which creates the branch and its worktree from origin or locally;
  - `app/services/designs/publisher.rb`: SLOT also accepts `design/[A-Za-z0-9_-]+`. `publish!` also writes `__flosis/screens.json`. Add `publish_changes!(thread)`, which writes `__changes/designs/<ctx>/<screen>.html` from `Designs::Changes`;
  - `app/services/designs/leak_guard.rb`: a turn's allowed roots are the four folders;
  - `lib/designs_template` and `app/services/designs/template.rb`: rename `design_system/` to `design-system/`; contexts become folders, with `designs/<context>/index.html` and a starter screen; add `inspirations/.keep`; drop `contexts.json` and the `?ctx=` code.
- Test: `test/services/designs/repo_test.rb`, `publisher_test.rb`, `leak_guard_test.rb`, `template_test.rb`.

**Interfaces:**
- Produces: `Repo#ls_files`, `#merge_base`, `#merges_between`, `#branch!`, `Publisher#publish_changes!(thread)` and `Publisher::SLOT`.

- [ ] **Step 1: Write the failing tests.**
  - `ls_files` lists `designs/` files at a ref.
  - `merges_between(base, master)` lists one merge after a thread merges.
  - `branch!` recovers a branch that only origin has.
  - Publishing `design/foo` lands in `<token>/design/foo/`, with `__flosis/screens.json`.
  - `publish_changes!` writes marked HTML.
  - The guard refuses `runtime/flosis.js` and `README.md` from a turn, and accepts `inspirations/a.png`.
  - The template has `design-system/` and no `contexts.json`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the four files. Expected: PASS.
- [ ] **Step 5: Commit** `feat: publish thread branches with their screens and changes`.

### Task 5: The runtime talks to the canvas

**Files:**
- Modify: `lib/designs_template/runtime/flosis.js`.
- Test: `test/services/designs/template_test.rb`, which checks the published runtime carries the message types. The behaviour itself is checked in the browser in Task 15.

**Interfaces:**
- **Produces, messages to `parent`:**
  - `{ type: "flosis:screen", context, screen, title }` on load;
  - `{ type: "flosis:missing", label, reason: "not-designed"|"other-context", context }` when a link inside `designs/` points to a screen not in `__flosis/screens.json`.
- **Produces, outlines:** elements with `data-flosis-change` get a dashed `#7c3aed` outline and a NEW or UPDATED badge.

- [ ] **Step 1: Write the failing test.** The template's runtime contains `flosis:screen`, `flosis:missing` and `data-flosis-change`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Read `__flosis/screens.json` relative to the root. The current context and screen come from the path `designs/<context>/<screen>.html`. Intercept clicks on same-repo links to missing screens.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: the design runtime reports its screen and missing links`.

### Task 6: Turns on threads

**Files:**
- Modify:
  - `app/services/designs/subject.rb`: add `ThreadSubject`, chosen for purpose `designs_thread`;
  - `app/services/designs/prompt.rb`: `thread_message(thread:, request:, context:, screen:)`, and the four-folder structure in BASE;
  - `app/jobs/designs/turn_job.rb`: the concurrency key for thread sessions is `"designs-thread-#{thread.id}"`. After the commit it publishes the branch, calls `publish_changes!`, computes chips with `Designs::Changes` (from the commit before the turn to the new one) into the reply's `data["chips"]`, and sets `thread.focus_*` from the first chip.
- Test: `test/services/designs/subject_test.rb`, `test/jobs/designs/turn_job_test.rb`.

**Interfaces:**
- Consumes: `DesignThread`, `Designs::Changes` and `Publisher#publish_changes!`.
- **Produces, `ThreadSubject`:**
  - `wip_branch` and `preview_slot` are `thread.branch`;
  - `checkout!` is `repo.branch!(thread.branch, from: thread.base_sha)`;
  - `api_key` is the project's.
- **Produces, reply data:** `ChatMessage#data` on a reply is `{ "chips" => [[screen, context, "M"|"+"], …] }`.

- [ ] **Step 1: Write the failing tests.**
  - A thread turn commits on `design/…`.
  - It publishes the slot and the changes variant.
  - Its reply carries chips for the changed screen.
  - It names a fresh thread's branch from its first message.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both files. Expected: PASS.
- [ ] **Step 5: Commit** `feat: design turns run on threads`.

### Task 7: The thread lifecycle

**Files:**
- Create: `app/services/designs/threads.rb`, `app/jobs/designs/merge_summary_job.rb`.
- Test: `test/services/designs/threads_test.rb`, `test/jobs/designs/merge_summary_job_test.rb`.

**Interfaces:**
- **Produces, starting and talking (`Designs::Threads`):**
  - `start!(project:, user:, text: nil, context: nil, screen: nil, task: nil) -> DesignThread`. It writes the system line "Branch <branch> created from master <hash>", or "Thread started from <KEY> · branch <branch> created from master <hash>". With text, it writes the user message and queues a turn.
  - `start_from_task!(task, user:) -> DesignThread`. The request is the task's current description.
  - `message!(thread, user:, text:, context:, screen:) -> DesignTurn`.
- **Produces, what changed under a thread:**
  - `description_change(thread) -> { from:, to:, lines: [["-"|"+", text]] } or nil`;
  - `update_description!(thread, user:)`. It posts a `kind: "diff"` message and queues a turn, then stores `described_text` and `described_version`.
  - `behind(thread) -> [DesignMerge]`, the merges on master since `base_sha`;
  - `update_master!(thread, user:)`. It merges master into the branch, posts `kind: "master"` with the merges, moves `base_sha`, and queues the check turn (a `resolve_conflicts` turn on a conflict).
- **Produces, merging:**
  - `merge!(thread, user: nil, how: "manual") -> DesignMerge`. It runs under the repo lock, and raises `Designs::Threads::Busy` while a turn of the thread is active.
- **Produces, merge summaries:** `Designs::MergeSummaryJob.perform_later(merge_id)` fills `summary` and `changes` through the Claude CLI (faked in tests).

- [ ] **Step 1: Write the failing tests.** One per interface above, plus:
  - a second merge while one runs raises `Busy`;
  - after merging thread A, thread B is behind by one merge;
  - `update_master!` with a conflict queues a `resolve_conflicts` turn.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Reuse `Repo#merge_master_into!` and `#merge_into_master!`.
- [ ] **Step 4: Run** both files. Expected: PASS.
- [ ] **Step 5: Commit** `feat: threads start, follow their task and master, and merge`.

### Task 8: Merge on Done

**Files:**
- Create: `app/jobs/designs/auto_merge_job.rb`.
- Modify: `app/services/jira_sync_service.rb`, where the `status` of a task goes from active to done.
- Test: `test/jobs/designs/auto_merge_job_test.rb`, `test/services/jira_sync_service_test.rb`.

- [ ] **Step 1: Write the failing tests.**
  - Sync moving a task to done queues the job for its open thread.
  - The job merges with `how: "auto"`.
  - Behind master without a conflict, it brings master in first and merges.
  - On a conflict it does not merge. It posts "Couldn't merge automatically: master changed the same lines. Update from master, then merge."
- [ ] **Step 2–4: Run, implement, run.** Expected: FAIL, then PASS.
- [ ] **Step 5: Commit** `feat: threads merge when their task is Done`.

### Task 9: The Designs module (list, canvas, library, settings)

**Files:**
- Create:
  - `app/controllers/workshop/designs_module_controller.rb`, with `show` taking `?thread=`, `?tab=system|components|history` and `?ctx=&screen=&mode=`;
  - views `app/views/workshop/designs_module/` (`show`, `_list_panel`, `_canvas`, `_system`, `_components`, `_history`, `_settings_drawer`);
  - Stimulus `app/javascript/controllers/designs_canvas_controller.js` (iframe scale-to-fit, postMessage, View as, modes, toasts) and `designs_immersive_controller.js` (Hide menus, remembered in localStorage, peek tabs).
- Modify:
  - `config/routes.rb`: `get "designs"` points to `designs_module#show`, keeping `as: :designs_overview`;
  - `app/views/layouts/_clar_sidebar.html.erb`: the Designs item is gated on `:designs`, with the build dot;
  - the workshop layout: a hook that lets immersive mode hide the top bar and the sidebar.
- Test: `test/controllers/workshop/designs_module_controller_test.rb`.

- [ ] **Step 1: Write the failing tests,** one per item of the spec's sections "Sidebar", "The module", "Panel: the list", "Canvas", "Library pages" and "Design settings", asserting the verbatim copy. The fixtures are a project with designs ready, a temp design repo built from the template, and one open thread.
- [ ] **Step 2–4: Run, implement, run.** Expected: FAIL, then PASS.
- [ ] **Step 5: Commit** `feat: the Designs module — threads list, canvas, library and settings`.

### Task 10: The thread panel and the dialogs

**Files:**
- Create:
  - `app/controllers/workshop/design_threads_controller.rb`, with `create` (New thread, and "+" for a fresh thread), `message`, `merge`, `update_description`, `update_master`, `generate_task` (GET runs the draft, POST creates the task), `draft` (polling) and `attach`;
  - views `app/views/workshop/design_threads/` (`_panel`, `_message`, `_banners`, `_new_modal`, `_generate_modal`, `_merge_modal`);
  - `app/jobs/designs/draft_task_job.rb`, which writes the title and description from the thread, adapted from DescribeJob.
- Modify: `config/routes.rb`.
- Test: `test/controllers/workshop/design_threads_controller_test.rb`, `test/jobs/designs/draft_task_job_test.rb`.

- [ ] **Step 1: Write the failing tests.** They cover every item of "Panel: a thread" and "Dialogs". "Create task · start Details Gathering" must:
  - make a pipeline task at `details` whose TaskDraft v1 is the description;
  - link the thread;
  - post "Task <KEY> created from this thread · Details Gathering started";
  - seed the Briefing and Details greetings.
- [ ] **Step 2–4: Run, implement, run.** Expected: FAIL, then PASS.
- [ ] **Step 5: Commit** `feat: design threads — conversation, banners, merge and generate task`.

### Task 11: Task strip, pipeline badge and Jira

**Files:**
- Modify:
  - `app/views/workshop/ideas/_designs_strip.html.erb`, which becomes the spec's strip on every stage;
  - `app/views/workshop/pipeline/_idea_row.html.erb`, which gets the badge;
  - `app/services/designs/jira_links.rb`, so links come from the thread's changed screens, plus the branch line;
  - `config/routes.rb`: `post "ideas/:id/design_thread"`, which is "Design with AI".
- Test: `test/controllers/workshop/ideas_controller_test.rb`, `pipeline_controller_test.rb`, `test/services/designs/jira_links_test.rb`.

- [ ] **Step 1: Write the failing tests.**
  - Each strip state: no thread; open; description changed; master changed; merged; a project without designs.
  - Each badge.
  - The Jira description has `/<KEY>/design/<ctx>/<screen>` links and the line "Designs: <repo> @ <branch> (merges into master when this task is Done)".
  - `PreviewEntriesController#task` resolves a KEY to the thread's branch.
- [ ] **Step 2–4: Run, implement, run.** Expected: FAIL, then PASS.
- [ ] **Step 5: Commit** `feat: the task strip, pipeline badges and Jira links follow threads`.

### Task 12: Setup form and the unattended import

**Files:**
- Create:
  - `app/controllers/workshop/design_setup_runs_controller.rb` (`new`, `create`, `edit`, `update`, `show` for progress, `retry`);
  - views `app/views/workshop/design_setup_runs/`;
  - `app/jobs/designs/setup_run_job.rb`.
- Modify:
  - `app/models/design_setup.rb`: `STEPS`, the seven labels from the spec with their minutes `[8, 2, 15, 5, 12, 15, 3]`, plus `percent` and `minutes_left`;
  - `app/services/designs/subject.rb`: `SetupSubject` uses the project's key, and with a thread it works on the thread's branch;
  - `DesignSetupRole`, which takes on the contexts.
- Test: `test/controllers/workshop/design_setup_runs_controller_test.rb`, `test/jobs/designs/setup_run_job_test.rb`.

- [ ] **Step 1: Write the failing tests.** They cover every item of "Setup form" and "Build progress". The job runs through the steps with a faked crawler and CLI, then:
  - commits to master;
  - records a `DesignMerge` with `how: "setup"` and the title "Initial import from staging";
  - a failure stops at the step with its error, and "Retry" resumes from it;
  - Re-import opens the thread "Re-import from staging" and does not merge.
- [ ] **Step 2–4: Run, implement, run.** Expected: FAIL, then PASS.
- [ ] **Step 5: Commit** `feat: Designs setup form and unattended import`.

### Task 13: Remove v1's surfaces

**Files:**
- Delete:
  - `Workshop::DesignsController` and its views;
  - `Workshop::DesignSetupsController` and `DesignSetupInputsController`, with their views;
  - `Workshop::ProjectDesignsController` and its view;
  - `configuration/_designs_tab`, `_designs_setup_inputs`, and the rotate action and route;
  - "Start in Designs" in `pipeline/_new_idea_modal`;
  - `Designs::Approval`, `SetupApproval`, `WorkingBranch` and `RenameForJiraJob`, with their tests.
- Modify: `config/routes.rb`, `Workshop::ConfigurationController::TAB_PERMISSIONS`, and the tests that referenced them.

- [ ] **Step 1:** Remove them. Then run every test file under `test/controllers/workshop`, `test/services/designs`, `test/jobs/designs` and `test/models`, one at a time.
- [ ] **Step 2:** Fix the references until those pass. The known pre-existing `reports_controller_test` failure is the one exception.
- [ ] **Step 3: Commit** `refactor: drop v1's per-task Designs screen, setup run and configurator tab`.

### Task 14: Final review, deploy, click-through

- [ ] **Step 1: Review.** Dispatch a fresh reviewer on the branch diff since `4ac2f6b`. Fix the Critical and Important findings with tests written first.
- [ ] **Step 2: Deploy.**
  - Push `production`.
  - Run `bin/rails tailwindcss:build`.
  - Deploy right after a 5-minute tick, with nothing claimed.
  - Check the migrations on MariaDB.
- [ ] **Step 3: Click through** production next to `ClearBacklog-3.html` and the mockup, screen by screen, with screenshots, on Kacper's account. The checks need no AI unless a Gold project with a key exists.
