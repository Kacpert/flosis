# Designs imports: Stop, a form before New import, code-first imports with feedback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Imports can be stopped and deleted, New import opens the setup form, and every import reads the app from its git history first, builds what it can (from the code where it cannot sign in) and ends with feedback the person can act on to import more.

**Architecture:** DesignSetup gains a stop (columns + Designs::ImportStop, respected by Designs::SetupRunJob) and a deletion (Designs::ImportDeletion). The setup form's saving moves to Designs::SetupForm, shared by the setup and New import. Designs::AppHistory keeps full bare clones of the app repositories; a new node MCP server (lib/designs_crawler/git.mjs, `flosis_git`) runs read-only git on them for every setup turn. The resync's change-finding turn becomes code-only. Contexts may be code-only, and failed sign-ins no longer stop a run. Turns leave suggestions (a `suggest` tool on flosis_browser, plus SignIn and AppRepos), stored as DesignImportSuggestion and shown as Feedback with actions that queue follow-up features (Designs::ImportMore).

**Tech Stack:** Rails 8.1, Minitest, MariaDB in production (JSON columns typed with `attribute`), Stimulus, Node 20 MCP servers (@modelcontextprotocol/sdk 1.32.1, zod 4), git.

**Spec:** docs/superpowers/specs/2026-11-22-designs-imports-code-first-design.md

## Global Constraints

- Ruby tests: `PARALLEL_WORKERS=1 bin/rails test <files>`; node tests: `cd lib/designs_crawler && node --test test/*.test.mjs`.
- Work on the `production` branch of the shared checkout; check `git branch --show-current` before each commit; `git add` explicit paths only; commit messages carry no Claude trailer.
- Production is MariaDB: every JSON column is declared `attribute :x, :json, default: …` on its model.
- Copy is plain English in the Workshop's voice; quoted copy below is exact.
- Claude never gets a shell: setup turns stay `--restricted`; git reaches Claude only through `flosis_git`.
- Passwords live only in the form and the sign-in script's stdin; never in suggestions, notes, messages or logs.
- What must reach production goes in code (resync prompt, SetupSubject notes and turn message), not the Library (map/feature/design-system prompts live there on production).
- New migrations use timestamps after 20261122100000.

## Review Focus

- A Stop that races the job: the job's own `stop`/`pause`/`give_up_feature` writes after the person's stop must not undo it or enqueue more work.
- Resume after Stop: the feature interrupted by the stop is built again, not left failed.
- git.mjs argument checking: every option that writes a file, reads a file outside the repository or runs a program is refused, including `--output=x` and `-Ox` spellings; output past the cap is cut with the note, never silently.
- A code-only context, or all contexts failing to sign in, must not stop a run nor send an empty browser config that breaks the browser server.
- Suggestions are deduped across the many sign-ins of one run (every feature signs in again) and never carry a password.

---

### Task 1: Stop

**Files:**
- Create: `db/migrate/20261122110000_add_stop_to_design_setups.rb`, `app/services/designs/import_stop.rb`, `app/views/workshop/design_imports/_stop_button.html.erb`, `test/services/designs/import_stop_test.rb`
- Modify: `app/models/design_setup.rb`, `app/jobs/designs/setup_run_job.rb`, `app/controllers/workshop/design_imports_controller.rb`, `app/controllers/workshop/design_setup_runs_controller.rb` (retry), `config/routes.rb`, `app/views/workshop/design_imports/_import.html.erb`, `app/views/workshop/designs_module/_imports.html.erb`, `app/views/workshop/design_setup_runs/show.html.erb`
- Test: `test/services/designs/import_stop_test.rb`, `test/jobs/designs/setup_run_job_test.rb`, `test/controllers/workshop/design_import_actions_test.rb`, `test/controllers/workshop/design_imports_pages_test.rb`

**Interfaces:**
- Produces: `design_setups.stopped_at` (datetime), `design_setups.stopped_by_id` (bigint, FK users, on_delete nullify); `DesignSetup#stopped?` (`stopped_at.present?`), `belongs_to :stopped_by, class_name: "User", optional: true`; `Designs::ImportStop.new(setup, user).stop!` → true when something was stopped; `DesignSetup::STOPPED_FEATURE = "Stopped by %s."`; route `stop_workshop_design_import_path(setup)` (POST).

- [ ] **Step 1: Write the failing tests**

`test/services/designs/import_stop_test.rb`:
```ruby
test "stopping a running import fails it as stopped and kills its turns' Claude" do
  # setup: running resync (status active, finished_at nil, unit_job_id "job-1", unit_deadline_at 10.minutes.from_now)
  # with a designs_setup ChatSession(design_setup: setup, claude_session_id: "sess-1") and a running DesignTurn
  killed = []
  Designs::SetupRunJob.killer = ->(id) { killed << id }
  assert Designs::ImportStop.new(setup, users(:one)).stop!
  setup.reload
  assert_equal [ "failed", users(:one), nil, nil ], [ setup.status, setup.stopped_by, setup.unit_job_id, setup.unit_deadline_at ]
  assert setup.stopped?
  assert_equal [ "sess-1" ], killed
  assert_equal [ "failed", "Stopped by #{users(:one).name}." ], [ turn.reload.status, turn.error ]
end

test "stopping a finished import's queue fails its queued and running features" do
  # setup: approved import with features todo, running, done
  Designs::ImportStop.new(setup, users(:one)).stop!
  assert_equal %w[failed failed done], [ todo, running, done ].map { |f| f.reload.status }
  assert_equal "Stopped by #{users(:one).name}.", todo.error
  assert_equal "approved", setup.reload.status
  refute setup.stopped?
end

test "an import that is not busy is left alone" do
  refute Designs::ImportStop.new(approved_without_queue, users(:one)).stop!
end
```
`test/jobs/designs/setup_run_job_test.rb`:
```ruby
test "the job's stop after the person's stop keeps the stopped import as it is"  # call job.send(:stop, setup, "boom") after ImportStop; status failed, error nil, stopped_at kept
test "a pause after a stop enqueues nothing"   # job.send(:pause, setup, 1.hour.from_now) on a stopped import → no enqueued SetupRunJob, paused_until nil
```
`test/controllers/workshop/design_import_actions_test.rb`:
```ruby
test "Stop stops a running import and says so"  # post stop_workshop_design_import_path(running); redirect to page; flash[:clar_toast] == "Import stopped"; reload.stopped?
test "Stop needs the configuration permission"  # a user without it → not stopped
test "Resume goes on with the feature the stop interrupted" # stopped resync with a feature failed at stopped_at + 1.second → post retry_workshop_design_setup_run_path(import: id) → status active, stopped_at nil, stopped_by nil, feature todo, SetupRunJob enqueued
```
`test/controllers/workshop/design_imports_pages_test.rb`:
```ruby
test "a running import shows Stop, a stopped one says who stopped it" # page of running import has button "Stop"; stopped one shows "Stopped", "Stopped by <name> at HH:MM. What is on master stays.", button "Resume"; list entry says "Stopped"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/designs/import_stop_test.rb test/jobs/designs/setup_run_job_test.rb test/controllers/workshop/design_import_actions_test.rb test/controllers/workshop/design_imports_pages_test.rb`
Expected: FAIL/ERROR (uninitialized constant Designs::ImportStop, undefined route, missing columns).

- [ ] **Step 3: Implement**

- Migration adds `stopped_at` and `stopped_by_id` (`add_reference :design_setups, :stopped_by, foreign_key: { to_table: :users, on_delete: :nullify }`); run `bin/rails db:migrate`.
- `Designs::ImportStop#stop!`: in `setup.with_lock`, a `running?` import → `update!(status: "failed", error: nil, stopped_at: now, stopped_by: user, unit_job_id: nil, unit_deadline_at: nil, paused_until: nil)`; a `follow_up?` import → its `pending` features `update!(status: "failed", stage: nil, finished_at: now, error: format(STOPPED_FEATURE, user.name))`; else return false. After the lock: each `DesignTurn` with status in `DesignTurn::ACTIVE` whose `chat_session.design_setup_id == setup.id` → `Designs::SetupRunJob.killer.call(session.claude_session_id)` then `turn.fail!(format(STOPPED_FEATURE, user.name))`.
- SetupRunJob: `stop` → `next if setup.done? || setup.stopped?`; `pause` → `next false if setup.stopped? || !setup.running? && !setup.follow_up?` (keep the job-id check).
- DesignSetupRunsController#retry: for a failed, unfinished import also clear `stopped_at`, `stopped_by`, and set features with `status: "failed"` and `finished_at >= stopped_at` back to `todo` (stage nil, error nil) when it was stopped.
- Controller `stop`: `require_permission!(:configuration)` already applies; `Designs::ImportStop.new(@import, current_user).stop!`; toast "Import stopped"; redirect to `helpers.import_page_path(@import)`.
- Views: `_stop_button` (button_to "Stop", confirm "Stop this import? What is on master stays, and you can resume it.", class `clar-btn !py-1.5 !px-3.5 !text-[12.5px]`), shown beside the title when `setup.busy? && import_actions?(setup) && can?(:configuration)`; the failed card's heading is "Stopped" and its text "Stopped by <name> at <HH:MM>. What is on master stays." when `setup.stopped?`, its button "Resume"; the list entry's status reads "Stopped" for a stopped import; the setup progress page (design_setup_runs/show) renders the same Stop button for a running first import.

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261122110000_add_stop_to_design_setups.rb db/schema.rb app/models/design_setup.rb app/services/designs/import_stop.rb app/jobs/designs/setup_run_job.rb app/controllers/workshop/design_imports_controller.rb app/controllers/workshop/design_setup_runs_controller.rb config/routes.rb app/views/workshop/design_imports/_stop_button.html.erb app/views/workshop/design_imports/_import.html.erb app/views/workshop/designs_module/_imports.html.erb app/views/workshop/design_setup_runs/show.html.erb test/services/designs/import_stop_test.rb test/jobs/designs/setup_run_job_test.rb test/controllers/workshop/design_import_actions_test.rb test/controllers/workshop/design_imports_pages_test.rb
git commit -m "feat: an import can be stopped from its page and resumed where it stopped"
```

### Task 2: Delete

**Files:**
- Create: `app/services/designs/import_deletion.rb`, `test/services/designs/import_deletion_test.rb`
- Modify: `app/models/design_setup.rb`, `app/controllers/workshop/design_imports_controller.rb`, `config/routes.rb`, `app/views/workshop/design_imports/_import.html.erb`
- Test: `test/services/designs/import_deletion_test.rb`, `test/controllers/workshop/design_import_actions_test.rb`

**Interfaces:**
- Consumes: `DesignSetup#stopped?` (Task 1).
- Produces: `DesignSetup#deletable?` (resync, failed, not busy, no feature `done`); `Designs::ImportDeletion.new(setup).delete!`; route `workshop_design_import_path(setup)` with DELETE.

- [ ] **Step 1: Write the failing tests**

`test/services/designs/import_deletion_test.rb` (with DesignRepoTestHelper):
```ruby
test "deleting an import removes its branches, chats, run folder and record" do
  # a stopped resync with a feature (branch wip/import-<id>-designs pushed to the remote and checked out as a worktree),
  # a designs_setup ChatSession with a DesignTurn and messages, a run_dir with a file
  Designs::ImportDeletion.new(setup).delete!
  refute DesignSetup.exists?(setup.id)
  refute ChatSession.exists?(session.id)
  refute repo.head("wip/import-#{setup.id}-designs")
  assert_nil repo.remote_head("wip/import-#{setup.id}-designs") # after fetch
  refute setup.run_dir.exist?
end
test "deletable? only for a failed resync that is not busy and has nothing on master" # resync failed → true; approved → false; first import failed → false; with a done feature → false
```
`test/controllers/workshop/design_import_actions_test.rb`:
```ruby
test "Delete removes a stopped import and goes back to the list" # delete workshop_design_import_path(stopped) → redirected to workshop_designs_overview_path(tab: "imports"), toast "Import deleted", record gone
test "Delete refuses an import whose work is on master" # done feature → record kept, toast "This import has work on master, so it stays."
```

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/designs/import_deletion_test.rb test/controllers/workshop/design_import_actions_test.rb`
Expected: FAIL (uninitialized constant, no route).

- [ ] **Step 3: Implement**

- `delete!`: branches = the `branch` of its features plus `Designs::BranchNames.import(feature)` of each; in `repo.synchronize` per name: remove its worktree if `repo.worktree_path(name).exist?`, `repo.delete_branch!(name) if repo.head(name)`, `repo.push!(":refs/heads/#{name}") if repo.remote_head(name)` (skip the repo part when `repo.initialized?` is false); then in a transaction `ChatSession.where(design_setup_id: setup.id).find_each(&:destroy!)` and `setup.destroy!`; then `FileUtils.rm_rf(setup.run_dir)` only when its path ends with `design-runs/<id>`.
- Controller `destroy`: refuse unless `@import.deletable?` (toast "This import has work on master, so it stays." for a done feature, else "Stop the import before deleting it."); else delete, toast "Import deleted", redirect to the imports list.
- View: a "Delete" button_to (method delete, confirm "Delete this import? Its branches and chats go; nothing on master changes.") beside Resume/Retry on the failed card when `setup.deletable? && can?(:configuration)`.

- [ ] **Step 4: Run the tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/import_deletion.rb app/models/design_setup.rb app/controllers/workshop/design_imports_controller.rb config/routes.rb app/views/workshop/design_imports/_import.html.erb test/services/designs/import_deletion_test.rb test/controllers/workshop/design_import_actions_test.rb
git commit -m "feat: an import that stopped before reaching master can be deleted with its branches and chats"
```

### Task 3: New import opens the form

**Files:**
- Create: `app/services/designs/setup_form.rb`, `test/services/designs/setup_form_test.rb`
- Modify: `app/controllers/workshop/design_setup_runs_controller.rb`, `app/controllers/workshop/design_imports_controller.rb`, `config/routes.rb`, `app/views/workshop/design_setup_runs/new.html.erb`, `app/views/workshop/designs_module/_imports.html.erb`
- Test: `test/services/designs/setup_form_test.rb`, `test/controllers/workshop/design_setup_runs_controller_test.rb`, `test/controllers/workshop/design_import_actions_test.rb`

**Interfaces:**
- Produces: `Designs::SetupForm.new(project, params).save` → true/false, `#error` → the refusal message (INCOMPLETE or the record's errors); `Designs::SetupForm::INCOMPLETE`, `REPO`, `SUPPORTED` (moved from the controller, which keeps aliases for the views); route `new_workshop_design_import_path` (GET); the view takes `@import_mode` (true on New import).

- [ ] **Step 1: Write the failing tests**

`test/services/designs/setup_form_test.rb`: the existing save rules, moved: saves stack, designs repo, app repos and contexts; refuses without a designs repo, an app repo or a context; keeps a saved password when left blank; refuses a new context without a password; reports a record error as `error`.
`test/controllers/workshop/design_import_actions_test.rb`:
```ruby
test "New import opens the form filled in" # get new_workshop_design_import_path → 200, h1 "New import", the app repos and the contexts prefilled, button "Start import", no FRAMEWORK chips
test "Start import saves the form and starts the import" # post workshop_design_imports_path with repos/contexts (a new context "Flosis staff") → resync created, SetupRunJob enqueued, role "Flosis staff" saved, redirect to its page
test "Start import with a missing context re-renders the form" # no contexts → 422, form shown with the INCOMPLETE alert, nothing created
```
Existing `design_setup_runs_controller_test.rb` keeps passing.

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/designs/setup_form_test.rb test/controllers/workshop/design_import_actions_test.rb test/controllers/workshop/design_setup_runs_controller_test.rb`
Expected: FAIL (no SetupForm, no `new` route).

- [ ] **Step 3: Implement**

- Move `form_params` handling, `save_form`, `repo_name`, `rows`, `origin` into `Designs::SetupForm` (params as given by the controller's permit); the app URL comes from the first context that has a URL (keep the project's when none has).
- DesignSetupRunsController uses it (`@refusal = form.error`).
- DesignImportsController: `new` (refuses like `create` does before master or while an import works, with the same toasts) renders `workshop/design_setup_runs/new` with `@project`, `@import_mode = true`, `@since = helpers.import_resync_from(project)`; `create` saves the form first (`render "workshop/design_setup_runs/new", status: :unprocessable_entity` with the alert on failure), then starts the resync as today. Exclude `new` from `load_import`.
- The view in import mode: back link to the imports list, h1 "New import", intro "What developers built since <Mon D>: check the app repositories and the contexts, then start. It runs in the background.", the Technology card and the designs repository input hidden (their values as hidden fields: framework, ui, ui_version, repo), the form posts to `workshop_design_imports_path`, submit "Start import", hint ready text "In the background. You can keep working.".
- `_imports.html.erb`: "New import" becomes a `link_to new_workshop_design_import_path` with the same classes.

- [ ] **Step 4: Run the tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/setup_form.rb app/controllers/workshop/design_setup_runs_controller.rb app/controllers/workshop/design_imports_controller.rb config/routes.rb app/views/workshop/design_setup_runs/new.html.erb app/views/workshop/designs_module/_imports.html.erb test/services/designs/setup_form_test.rb test/controllers/workshop/design_import_actions_test.rb test/controllers/workshop/design_setup_runs_controller_test.rb
git commit -m "feat: New import opens the setup form, to change the links or add a context before it starts"
```

### Task 4: The app's history and the git tool

**Files:**
- Create: `app/services/designs/app_history.rb`, `lib/designs_crawler/git_lib.mjs`, `lib/designs_crawler/git.mjs`, `lib/designs_crawler/test/git_lib.test.mjs`, `test/services/designs/app_history_test.rb`
- Modify: `app/services/designs/app_changes.rb`, `app/services/designs/subject.rb` (SetupSubject), `app/jobs/designs/setup_run_job.rb`, `test/services/designs/app_changes_test.rb`, `test/services/designs/subject_test.rb`, `test/jobs/designs/import_resync_test.rb`
- Test: as listed.

**Interfaces:**
- Produces: `Designs::AppHistory.new(project)`: `#path(repo)` → Pathname `<designs_dir>/app-history/<n>-<repo.parameterize>.git` (n = 1-based index in `AppRepos#repos`), `#fetch!` → `[{ "repo", "branch", "path", "sha" }]` (clones bare and full on first use, else `git fetch --prune origin +refs/heads/*:refs/heads/*`; a repository that fails is skipped with `setup&.note!`), `#clones` → `{ "owner/name" => path }` for the clones that exist, `#git(repo, *args)` (GitRunner on the clone, no token). `AppChanges#fetch!` rows become `{ "repo", "branch", "from", "to", "commits", "stat" }` (stat: `git diff --stat=160 --stat-count=300 from to -- . <EXCLUDED>`, nil when unchanged). SetupSubject: `GIT_TOOL = "mcp__flosis_git__git"`, `GIT_NOTE`; `with_mcp` adds the `flosis_git` server (`node <crawler_dir>/git.mjs`, env `FLOSIS_GIT_REPOS` = JSON of `AppHistory#clones`) when any clone exists; `tools` includes GIT_TOOL then. git.mjs: tool `git` `{ repo: string, args: string[] }`. git_lib.mjs exports `ALLOWED`, `checkArgs(args) → { ok, error?, args? }` (args with forced flags), `cap(text, limit) → string`, `gitEnv(home) → object`.

- [ ] **Step 1: Write the failing tests**

`lib/designs_crawler/test/git_lib.test.mjs` (node:test):
```js
test("allows read-only subcommands and adds the safe flags", () => {
  assert.deepEqual(checkArgs(["diff", "a..b", "--", "config/routes.rb"]).args, ["diff", "--no-ext-diff", "--no-textconv", "a..b", "--", "config/routes.rb"])
  assert.equal(checkArgs(["log", "--oneline", "-n", "20"]).ok, true)
})
test("refuses subcommands that change anything", () => {
  for (const sub of ["push", "fetch", "checkout", "branch", "config", "gc", "update-ref", "archive", "format-patch"]) assert.equal(checkArgs([sub]).ok, false)
})
test("refuses options that write, read outside or run programs, in every spelling", () => {
  for (const bad of [["diff", "--output=x"], ["diff", "--output", "x"], ["diff", "--ext-diff"], ["diff", "--no-index", "/etc/passwd", "x"],
                     ["blame", "--contents", "/etc/passwd", "f"], ["blame", "-S", "revs", "f"], ["blame", "--ignore-revs-file=x", "f"],
                     ["grep", "-f", "/etc/passwd"], ["grep", "-Ovim", "x"], ["grep", "--open-files-in-pager", "x"], ["log", "-c", "x=y"],
                     ["log", "--git-dir=/x"], ["show", "--textconv", "HEAD"], ["cat-file", "--filters", "HEAD:x"]])
    assert.equal(checkArgs(bad).ok, false, bad.join(" "))
})
test("cuts what is too long with a note", () => {
  assert.match(cap("x".repeat(200), 100), /\(cut at 100 bytes: narrow it with a path, a range or --stat\)$/)
  assert.equal(cap("short", 100), "short")
})
test("runs git without the user's or the system's config", () => {
  const env = gitEnv("/tmp/empty")
  assert.equal(env.GIT_CONFIG_NOSYSTEM, "1"); assert.equal(env.GIT_CONFIG_GLOBAL, "/dev/null"); assert.equal(env.HOME, "/tmp/empty")
  assert.equal(env.GIT_PAGER, "cat"); assert.equal(env.GIT_TERMINAL_PROMPT, "0")
})
```
`test/services/designs/app_history_test.rb` (local bare remotes through `Designs::AppRepos.url_for`, as app_changes_test does):
```ruby
test "fetch! clones each app repository bare and full, then fetches it" # first fetch! → path exists, `git --git-dir <path> rev-list --count HEAD` == 2 after two commits; a new commit pushed, fetch! again → sha is the new head
test "clones lists the clones that exist" # → { "acme/app" => path.to_s }
```
`test/services/designs/app_changes_test.rb`: rows now `{ repo, branch, from, to, commits, stat }`, stat includes the changed path, `app_commits` records `to`, no file under `run_dir/changes`; the existing baseline cases keep their from/to.
`test/services/designs/subject_test.rb`:
```ruby
test "a setup turn has the git tool on the app's history when clones exist" # stub AppHistory#clones → { "acme/app" => "/x.git" }; with_mcp config JSON has mcpServers.flosis_git with args ending git.mjs and env FLOSIS_GIT_REPOS == '{"acme/app":"/x.git"}'; tools include "mcp__flosis_git__git"; system_text includes "# The app's history"
test "without clones there is no git server"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd lib/designs_crawler && node --test test/git_lib.test.mjs; cd ../.. && PARALLEL_WORKERS=1 bin/rails test test/services/designs/app_history_test.rb test/services/designs/app_changes_test.rb test/services/designs/subject_test.rb`
Expected: FAIL (module not found; uninitialized constant Designs::AppHistory; old row shape).

- [ ] **Step 3: Implement**

- git_lib.mjs: `ALLOWED = ["log","show","diff","blame","grep","ls-tree","rev-parse","rev-list","shortlog","cat-file","merge-base","diff-tree","for-each-ref","describe","name-rev"]`; refused options by prefix match on the option name before `=` and for short options by their first two characters: `--output`, `--ext-diff`, `--textconv`, `--filters`, `--no-index`, `--contents`, `--ignore-revs-file`, `--open-files-in-pager`, `--exec`, `--upload-pack`, `--config-env`, `--git-dir`, `--work-tree`, `--namespace`, `--paginate`, `-O`, `-c`, `-C`, `-p` only as a global option (never: args always start with the subcommand), grep's `-f` and `--file`, blame's `-S`; options after `--` are paths and are not checked; diff/show/log/diff-tree get `--no-ext-diff --no-textconv` right after the subcommand, grep gets `--no-textconv`. `cap(text, limit)` cuts at `limit` bytes on a character boundary and appends `\n… (cut at <limit> bytes: narrow it with a path, a range or --stat)`. `gitEnv(home)` returns only PATH from process.env plus the variables of the spec.
- git.mjs: MCP server `flosis_git` (same SDK and `tool()` wrapper style as files.mjs), tool `git` with zod `{ repo: z.enum(Object.keys(repos)), args: z.array(z.string()).min(1) }`; runs `execFile("git", ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never", "--git-dir", repos[repo], ...checked.args], { env: gitEnv(tmpHome), timeout: 30_000, maxBuffer: 8 MB })`; returns `cap(stdout || stderr, 100_000)`; a refusal or a failure is an `isError` text. Exits on stdin close and SIGTERM.
- AppHistory: as the Interfaces say; folders 0700; uses `Designs::AppRepos.url_for` and the project's GitHub token through GitRunner; `fetch!` takes an optional setup for notes.
- AppChanges: `from`/`to` from AppHistory's clone (fetched in `fetch!`), `commits` = `rev-list --count from..to`, `stat` as above; `app_commits` = `to`; no diff files.
- SetupRunJob: `read_repos` also runs `Designs::AppHistory.new(setup.project).fetch!(setup)` (a failure is a note, never a stop); `follow_up` fetches it when `AppHistory#clones` is empty. Add a seam `app_history` (default `->(setup) { Designs::AppHistory.new(setup.project).fetch!(setup) }`) and stub it in the job tests that stub `app_repos`.
- SetupSubject: GIT_NOTE (system text, only when clones exist):
  "# The app's history\n\nThe git tool runs read-only git on the app's repositories, with their whole history: log, show, diff, blame, grep and the like. Use it to see what changed and why: git log --stat <from>..<to>, then git diff <from> <to> -- <path> for the paths that matter, as a developer reviewing the changes would. Read the files themselves in the read-only copies."; remove the changes_dir line from `readable` and `add_dirs`.

- [ ] **Step 4: Run the tests to verify they pass** — same commands, plus `PARALLEL_WORKERS=1 bin/rails test test/jobs/designs/`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/app_history.rb app/services/designs/app_changes.rb app/services/designs/subject.rb app/jobs/designs/setup_run_job.rb lib/designs_crawler/git_lib.mjs lib/designs_crawler/git.mjs lib/designs_crawler/test/git_lib.test.mjs test/services/designs/app_history_test.rb test/services/designs/app_changes_test.rb test/services/designs/subject_test.rb test/jobs/designs/
git commit -m "feat: import turns read the app's whole git history through a read-only git tool"
```

### Task 5: A code-first look at what changed

**Files:**
- Modify: `app/services/designs/setup_prompts.rb` (resync), `app/services/designs/subject.rb`, `app/jobs/designs/setup_run_job.rb` (find_changes, resync_request), `test/jobs/designs/import_resync_test.rb`, `test/services/designs/subject_test.rb`, `test/services/designs/setup_prompts_test.rb`

**Interfaces:**
- Consumes: AppChanges rows (Task 4), GIT_TOOL (Task 4).
- Produces: SetupSubject `code_only_turn?` (phase "resync"): tools = `TurnJob::TOOLS + MAP_TOOLS + [GIT_TOOL] (+ SUGGEST_TOOL from Task 7)`, no BROWSER_TOOLS, BROWSER_NOTE replaced by CODE_ONLY_NOTE.

- [ ] **Step 1: Write the failing tests**

`test/jobs/designs/import_resync_test.rb`:
```ruby
test "finding what changed signs nobody in and gives the history range" # count sign_in calls during the find_changes unit → 0 (features still sign in); the resync request includes "acme/app: aaaaaaa..bbbbbbb (3 commits)" and the stat line, and "git log --stat"
test "nothing changed still finishes" # existing case adapted to the new row shape (from == to, stat nil)
```
`test/services/designs/subject_test.rb`:
```ruby
test "the resync turn reads code only" # setup.phase = "resync": tools include save_features and git, exclude mcp__flosis_browser__open; system_text includes "# This turn reads code only" and not "# This turn's browser"
```
`test/services/designs/setup_prompts_test.rb`:
```ruby
test "the resync prompt starts from the code" # SEEDS["resync"][:body] includes "git tool", "routes", "whatever the framework calls them", "roles and permissions", and not "Open its screens in the browser"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/jobs/designs/import_resync_test.rb test/services/designs/subject_test.rb test/services/designs/setup_prompts_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

- `find_changes`: no `sign_in`; the request lists, per changed repo, "- <repo>[ @ <branch>]: <from7>..<to7> (<n> commits)" then its stat in a fenced block, under "## What changed in the app since <since_label>"; plus the map, as today.
- Resync seed body (code only, as the spec's section 4 says): read the history with the git tool (`git log --stat <from>..<to>`, then `git diff` per path), the routes whatever the framework calls them (config/routes.rb, a pages or app folder, a router's configuration, urls.py…), the navigation, views, components and styles the changes touch, and the roles and permissions; decide touched and new features; save with save_features once; a role the contexts do not cover is a suggestion (Task 7 wording: "leave a suggestion with the suggest tool"); write no files, open no browser.
- SetupSubject: CODE_ONLY_NOTE "# This turn reads code only\n\nThis turn has no browser: it works from the app's code and history alone. What the base prompt says about the browser does not apply."; `tools`/`system_text` per `code_only_turn?`.

- [ ] **Step 4: Run the tests to verify they pass** — same command plus `test/jobs/designs/`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/setup_prompts.rb app/services/designs/subject.rb app/jobs/designs/setup_run_job.rb test/jobs/designs/import_resync_test.rb test/services/designs/subject_test.rb test/services/designs/setup_prompts_test.rb
git commit -m "feat: a new import finds what changed from the code and its history, without a browser"
```

### Task 6: Contexts built from the code

**Files:**
- Create: `db/migrate/20261122110100_add_code_only_to_design_setup_roles.rb`
- Modify: `app/models/design_setup_role.rb`, `app/models/design_setup_feature.rb`, `app/services/designs/sign_in.rb`, `app/services/designs/subject.rb`, `app/jobs/designs/setup_run_job.rb`, `app/services/designs/setup_form.rb`, `app/views/workshop/design_setup_runs/_context_row.html.erb`, `app/views/workshop/design_setup_runs/new.html.erb`, `app/javascript/controllers/designs_setup_form_controller.js`, `app/views/workshop/design_imports/_built.html.erb`
- Test: `test/models/design_setup_role_test.rb` (create if missing), `test/services/designs/sign_in_test.rb`, `test/services/designs/subject_test.rb`, `test/services/designs/setup_form_test.rb`, `test/jobs/designs/setup_run_job_test.rb`, `test/controllers/workshop/design_imports_pages_test.rb`

**Interfaces:**
- Produces: `design_setup_roles.code_only` (boolean, default false, null false); `DesignSetupRole#signs_in?` (`!code_only`); `design_setup_features.from_code` (json, `attribute :from_code, :json, default: []`); `Designs::SignIn#call` returns `{ slug => bool }` for every context (code-only ones false) and never raises because nobody signed in; SetupSubject `context_lines` mark "from the code".

- [ ] **Step 1: Write the failing tests**

```ruby
# design_setup_role_test.rb
test "a code-only context needs only its name" # DesignSetupRole.new(project:, name: "Flosis staff", code_only: true).valid? → true; without code_only and login → invalid
# sign_in_test.rb
test "code-only contexts are not signed in" # runner receives only the roles with a login; result has "2-flosis-staff" => false
test "when nobody can sign in the run goes on, noted" # runner returns all not ok, pause 0 → call returns all false, no raise, a note "Nobody could sign in…"
test "with only code-only contexts nothing runs" # runner never called; all false
# subject_test.rb
test "the contexts list says which are built from the code" # one role signed in (state file present), one code-only, one whose state is missing → lines "Admin: browser 1-admin, designs/admin/", "Flosis staff: no browser (no login): build from the code, designs/flosis-staff/", "Manager: no browser (could not sign in): build from the code, designs/manager/"; system_text includes "# Contexts built from the code" when any line is from the code
# setup_form_test.rb
test "a context with No login is saved code-only without URL, login or password"
# setup_run_job_test.rb
test "a feature records the contexts it was built from the code for" # sign_in stub → { "1-admin" => true, "2-staff" => false }; feature contexts %w[1-admin 2-staff] → feature.from_code == ["2-staff"] after its unit
test "nobody signing in no longer stops the run" # sign_in stub returns all false → run goes on (not failed)
# design_imports_pages_test.rb
test "Built says which contexts were built from the code" # feature with from_code ["2-staff"] → "From code: Flosis staff"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/models/design_setup_role_test.rb test/services/designs/sign_in_test.rb test/services/designs/subject_test.rb test/services/designs/setup_form_test.rb test/jobs/designs/setup_run_job_test.rb test/controllers/workshop/design_imports_pages_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

- Migration: `code_only` on design_setup_roles; `from_code` (json, null) on design_setup_features.
- DesignSetupRole: `validates :login_url, :username, presence: true, unless: :code_only?`; password on create unless code_only.
- SignIn#call: roles with a login only; none → `{}` merged with code-only slugs false (no sign-in run); after ATTEMPTS of nobody signing in → note "Signing in" / "Nobody could sign in to the test environment: <reasons>. Every context is built from the code." and return all false (no raise). "The sign-in could not run" after ATTEMPTS → same treatment with its message. (Task 7 adds suggestions here.)
- SetupSubject: the Contexts lines as the test says (a context has a browser when its state file exists now); CODE_CONTEXTS_NOTE (only when a context is from the code): "# Contexts built from the code\n\nA context with no browser is built from the app's code: its routes, permissions, navigation, views and components, with fake data of the kind its views show. Say in a <missing> note that its screens were built from the code and not checked against the app."; browser_config already lists only signed-in contexts.
- SetupRunJob: after each feature's sign-in (`features` and `follow_up`), `feature.update!(from_code: feature contexts (all contexts when blank) whose sign-in result is false)`.
- SetupForm: a context row with `code_only` "1" needs only a name; its URL/login/password are cleared.
- Context row: a sixth column, a checkbox `contexts[i][code_only]` labelled "No login" (title "Build this context from the code, without signing in"); the grid template gets a column for it; the JS check counts a row with a name and No login as a context.
- `_built.html.erb`: "From code: <names>" on a feature whose `from_code` is present (names from the roles by slug).

- [ ] **Step 4: Run the tests to verify they pass** — same command plus `test/jobs/designs/ test/controllers/workshop/design_setup_runs_controller_test.rb`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261122110100_add_code_only_to_design_setup_roles.rb db/schema.rb app/models/design_setup_role.rb app/models/design_setup_feature.rb app/services/designs/sign_in.rb app/services/designs/subject.rb app/jobs/designs/setup_run_job.rb app/services/designs/setup_form.rb app/views/workshop/design_setup_runs/_context_row.html.erb app/views/workshop/design_setup_runs/new.html.erb app/javascript/controllers/designs_setup_form_controller.js app/views/workshop/design_imports/_built.html.erb test/models/design_setup_role_test.rb test/services/designs/sign_in_test.rb test/services/designs/subject_test.rb test/services/designs/setup_form_test.rb test/jobs/designs/setup_run_job_test.rb test/controllers/workshop/design_imports_pages_test.rb
git commit -m "feat: a context without a login, or one that cannot sign in, is built from the code"
```

### Task 7: Suggestions

**Files:**
- Create: `db/migrate/20261122110200_create_design_import_suggestions.rb`, `app/models/design_import_suggestion.rb`, `test/models/design_import_suggestion_test.rb`
- Modify: `app/models/design_setup.rb`, `lib/designs_crawler/browser.mjs`, `lib/designs_crawler/test/browser.test.mjs`, `app/services/designs/subject.rb`, `app/jobs/designs/setup_run_job.rb`, `app/services/designs/sign_in.rb`, `app/services/designs/app_repos.rb`
- Test: as listed plus `test/jobs/designs/setup_run_job_test.rb`, `test/services/designs/sign_in_test.rb`, `test/services/designs/subject_test.rb`

**Interfaces:**
- Produces: `DesignImportSuggestion` (belongs_to :design_setup; kind in `%w[context sign_in other]`; status in `%w[open done dismissed]`; `attribute :features, :json, default: []`; `scope :open`); `DesignImportSuggestion.record!(setup, kind:, title:, detail: nil, context_name: nil, role: nil, features: [])` → finds by `[design_setup_id, key]` (key: `"context:<context_name.parameterize>"`, `"sign_in:<role.id>"`, `"other:<title.parameterize.first(80)>"`) and leaves an existing one as it is; `DesignSetup has_many :suggestions, class_name: "DesignImportSuggestion", dependent: :delete_all`; SetupSubject `SUGGEST_TOOL = "mcp__flosis_browser__suggest"`, `SUGGEST_NOTE`; browser config `suggestionsPath`; SetupRunJob `read_suggestions!(setup)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# design_import_suggestion_test.rb
test "record! keeps one suggestion per thing" # twice context "Flosis staff" → 1 row; title/detail of the first kept
test "a sign-in suggestion is keyed by its context"
# setup_run_job_test.rb
test "a turn's suggestions become the import's" # turn_runner stub writes two JSON lines to run_dir/suggestions.jsonl ({"kind":"context","title":"Flosis staff can see the Library","context":"Flosis staff","features":["library"]} and {"kind":"other","title":"No invoices on staging"}) → setup.suggestions.open.count == 2, file gone
# sign_in_test.rb
test "a context that cannot sign in becomes a suggestion" # one fails with "Wrong password" → suggestion kind sign_in, role, title "Product Owner could not sign in", detail "Wrong password." ; repeated call → still 1
# subject_test.rb
test "setup turns may suggest" # tools include mcp__flosis_browser__suggest for map, feature and resync; system_text includes "# When you need something from the person"; browser_config includes suggestionsPath
```
`lib/designs_crawler/test/browser.test.mjs`: following the file's existing pattern for save_features, a test that `suggest` appends one JSON line `{ kind, title, detail, context, features }` to `suggestionsPath`, refuses an unknown kind, and is absent when the config has no `suggestionsPath`.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd lib/designs_crawler && node --test test/browser.test.mjs; cd ../.. && PARALLEL_WORKERS=1 bin/rails test test/models/design_import_suggestion_test.rb test/jobs/designs/setup_run_job_test.rb test/services/designs/sign_in_test.rb test/services/designs/subject_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

- Migration: `design_import_suggestions` (design_setup_id FK on_delete cascade, kind, key, title, detail text, context_name, design_setup_role_id FK on_delete nullify, features json, status default "open", acted_by_id FK users nullify, acted_at, timestamps; unique index [design_setup_id, key]).
- browser.mjs: `suggest` tool when `config.suggestionsPath` (any non-designOnly config): `{ kind: z.enum(["context","other"]), title: z.string().min(1).max(200), detail: z.string().max(2000).optional(), context: z.string().max(120).optional(), features: z.array(z.string()).max(30).optional() }` → appends one JSON line; returns "Noted for the person."
- SetupSubject: browser_config `suggestionsPath: run_dir/suggestions.jsonl`; SUGGEST_TOOL in `tools` for every phase; SUGGEST_NOTE: "# When you need something from the person\n\nIf something keeps you from importing the app as it is, and only the person can give it, leave a suggestion with the suggest tool, once per thing, and go on with what you can: a role the run's contexts do not cover (kind context: name the role and the map's features it has), data or an integration the test environment lacks, a repository you could not read (kind other). Never ask for a password. Nothing else is a suggestion."
- SetupRunJob: `read_suggestions!(setup)` after every turn it runs (run_turn!, features, follow_up): reads and deletes the file, `record!` each valid line (kind context → context_name; other → title), ignoring malformed lines.
- SignIn: a failed context → `record!(kind: "sign_in", role:, title: "<name> could not sign in", detail: "<message>.")`; "Nobody could sign in"/"could not run" → `record!(kind: "other", title: "Nobody could sign in", detail: …)`.
- AppRepos: a repository that could not be read → `record!(kind: "other", title: "<repo> could not be read", detail: …)`.

- [ ] **Step 4: Run the tests to verify they pass** — same commands plus `test/jobs/designs/`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261122110200_create_design_import_suggestions.rb db/schema.rb app/models/design_import_suggestion.rb app/models/design_setup.rb lib/designs_crawler/browser.mjs lib/designs_crawler/test/browser.test.mjs app/services/designs/subject.rb app/jobs/designs/setup_run_job.rb app/services/designs/sign_in.rb app/services/designs/app_repos.rb test/models/design_import_suggestion_test.rb test/jobs/designs/setup_run_job_test.rb test/services/designs/sign_in_test.rb test/services/designs/subject_test.rb
git commit -m "feat: import turns, sign-ins and repository reads leave suggestions for the person"
```

### Task 8: Feedback and importing more

**Files:**
- Create: `app/services/designs/import_more.rb`, `app/controllers/workshop/design_import_suggestions_controller.rb`, `app/views/workshop/design_imports/_feedback.html.erb`, `test/services/designs/import_more_test.rb`, `test/controllers/workshop/design_import_suggestions_controller_test.rb`
- Modify: `config/routes.rb`, `app/views/workshop/design_imports/_import.html.erb`, `app/views/workshop/designs_module/_imports.html.erb`
- Test: as listed plus `test/controllers/workshop/design_imports_pages_test.rb`

**Interfaces:**
- Consumes: DesignImportSuggestion (Task 7), `DesignSetupRole#code_only` (Task 6), `DesignSetup#start_work!`.
- Produces: `Designs::ImportMore.new(setup).context!(role, suggestion)` → the queued features; routes `add_login_workshop_design_import_suggestion_path(import, suggestion)`, `from_code_…`, `fix_login_…`, `dismiss_…` (POST).

- [ ] **Step 1: Write the failing tests**

```ruby
# import_more_test.rb
test "a context's features from the map are queued, one each, for that context only" # map has "library" (Library) and "billing"; suggestion features ["library", "billing"] → two todo features "Library · as Flosis staff", contexts [slug], brief starts with the map brief and ends "Build only what Flosis staff sees.", source "added", queued_at set
test "without features named, one feature finds the context's screens" # → "Flosis staff's screens", brief = suggestion detail + "\nFind what Flosis staff has in the app and build its screens."
# design_import_suggestions_controller_test.rb
test "Build from code adds a code-only context and imports its screens" # post from_code → role code_only "Flosis staff", suggestion done (acted_by), features queued, SetupRunJob enqueued, redirect to the import page with toast "Importing Flosis staff from the code"
test "Add login adds the context with its login and imports its screens" # params login_url, login, password → role with credentials; toast "Importing Flosis staff"
test "Add login without a password shows the problem" # → nothing created, toast "Fill in the login URL, the login and the password."
test "Fix login saves the new login and imports that context again" # sign_in suggestion → role updated (password changed), features queued for that context ("<feature> · as <name>" for each done feature of the import whose contexts include it, else one "<name>'s screens"), suggestion done
test "Dismiss sets it aside"
test "only people with the configuration permission act on suggestions"
# design_imports_pages_test.rb
test "Feedback shows the open suggestions once the import is over" # approved import with a context and a sign_in suggestion → "FEEDBACK · 2", their titles, buttons "Build from code", "Add login", "Fix login", "Dismiss"; a running import does not show the section; list entry "2 suggestions"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `PARALLEL_WORKERS=1 bin/rails test test/services/designs/import_more_test.rb test/controllers/workshop/design_import_suggestions_controller_test.rb test/controllers/workshop/design_imports_pages_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

- ImportMore#context!: map features (`project.design_feature_map.index_by(&:key)`) for the suggestion's `features`, at most 10; each → `setup.features.create!(name: "<name> · as <context>", key: DesignSetupFeature.key_for("<key>-as-<context>", taken), position: max+1, source: "added", status: "todo", queued_at: now, contexts: [slug], screens: map screens, brief: "<map brief>\n\nBuild only what <context> sees.")`; none → one feature as the test says; then `setup.start_work!`. A sign_in fix uses the import's done features whose contexts include the role's slug (all done features when their contexts are blank) instead of the map's.
- Controller (Workshop::BaseController, `require_permission!(:designs)` and `(:configuration)`, the import from `current_workshop_project.design_setups`, the suggestion from it): `add_login` (creates the role: name = context_name, login_url, username, password, position last; invalid → toast), `from_code` (role code_only), `fix_login` (updates the role; password required), `dismiss`; each marks the suggestion done/dismissed with acted_by/acted_at and redirects to `helpers.import_page_path(import)`.
- `_feedback.html.erb`: heading "FEEDBACK · n" (the style of "SET ASIDE · n"), one clar-card per open suggestion: bold title, muted detail, actions by kind; Add login and Fix login open an inline form (a `<details>` with Login URL, Login, Password inputs and a submit) — fields prefilled from the role for Fix login (URL, login). Rendered above Built when `!setup.running? && setup.suggestions.open.any? && import_actions?(setup)` (read-only list for people without configuration).
- List entry: "· n suggestions" when open ones exist.

- [ ] **Step 4: Run the tests to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/import_more.rb app/controllers/workshop/design_import_suggestions_controller.rb app/views/workshop/design_imports/_feedback.html.erb config/routes.rb app/views/workshop/design_imports/_import.html.erb app/views/workshop/designs_module/_imports.html.erb test/services/designs/import_more_test.rb test/controllers/workshop/design_import_suggestions_controller_test.rb test/controllers/workshop/design_imports_pages_test.rb
git commit -m "feat: an import ends with feedback whose actions import more"
```

### Task 9: The deploy uploads the node tools

**Files:**
- Modify: `lib/capistrano/tasks/designs_crawler.rake`, `config/deploy.rb`

**Interfaces:**
- Produces: `cap production setup:designs_crawler_files` (uploads `lib/designs_crawler/*.mjs` into `shared/designs_crawler`, nothing else), run after `deploy:published`.

- [ ] **Step 1: Add the task and the hook**

The task uploads each `lib/designs_crawler/*.mjs` with `upload!` (no npm, no Playwright); `after "deploy:published", "setup:designs_crawler_files"` in config/deploy.rb.

- [ ] **Step 2: Verify the task is defined**

Run: `bundle exec cap -T 2>/dev/null | grep designs_crawler_files`
Expected: one line naming the task.

- [ ] **Step 3: Commit**

```bash
git add lib/capistrano/tasks/designs_crawler.rake config/deploy.rb
git commit -m "chore: every deploy uploads the Designs node tools, so git.mjs and the browser stay current"
```
