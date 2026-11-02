# Workshop Designs — Plan 5: The Setup Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Flosis staff member starts a setup run for a project. Flosis crawls the running app as each role, logged in with stored credentials, and reads the app's code, plus Figma and other materials when given. Then, in three reviewed phases on `wip/setup` — design system, components, the current screens — Claude recreates the app in the design repo. Approval merges it all into `master`.

**Architecture:**
- **Inputs** are a staff-only section of the project's Designs configuration: app URL, credentials per role (encrypted), Figma URLs and uploaded materials.
- **The crawler** is a Node + Playwright script outside the Rails app. It reads its input (credentials included) from stdin and writes a bundle to a folder in the project's directory. `Designs::CrawlJob` runs it.
- **The session.** Setup is a project-level `ChatSession` (purpose `designs_setup`) on the Plan 2 screen.
- **Subjects.** The turn runner is generalised through a small subject object, so a task turn and a setup turn differ only in branch, prompt, key and extra read-only folders.
- **The key.** Setup turns run on Flosis's own key (`FLOSIS_DESIGNS_SETUP_API_KEY`), never on the project's.

**Tech Stack:** Rails 8.1, Minitest, Active Storage (local service, already used by `Task#attachments`), Node 20 on the server, Playwright (Chromium), Solid Queue.

**Spec:** `docs/superpowers/specs/2026-10-30-workshop-designs-design.md` ("The setup run (bootstrap)", "Risks to verify first"). **Builds on:** Plans 1–4. Check `Designs::TurnJob` (and its `claude_factory`), the `Designs::Approval` internals, the Plan 2 screen partials and the Plan 3 `LibraryEntry` before starting.

## Global Constraints

- Everything in Plan 1's Global Constraints still holds.
- **Who sees setup.** Every setup screen, input and action is Flosis-staff only. Anyone else gets a 404, workspace admins included.
- **Credentials:**
  - Role passwords are stored encrypted and are never rendered back, logged, or put in argv or the environment.
  - They reach the crawler only on stdin.
  - The crawl bundle must not contain them: the crawler removes `input[type=password]` values from saved DOM.
  - The leak guard's `secrets:` include every role password.
- **Account.** Setup turns run on `ENV["FLOSIS_DESIGNS_SETUP_API_KEY"]` only. Without it, setup refuses to start with `"Flosis's setup key is not configured (FLOSIS_DESIGNS_SETUP_API_KEY)."`.
- **Phases:** `design_system` → `components` → `designs`, then the run is approved. All three work on `wip/setup`, and approval merges `wip/setup` into `master` with the tag `approved/setup/<n>`.
- **Phase prompts** are library entries (kind `base_prompt`): `setup-design-system`, `setup-components` and `setup-designs`. They are seeded by migration and editable by staff.
- **Contexts.** The designs phase must create `designs/contexts.json` with a `permissions` dimension whose values are the crawled role names.

## Review Focus

1. **A login that fails for one role** (a wrong password, a changed form) must not sink the whole crawl. That role is marked failed in `crawl.json`, and the others carry on.
   → Task 4 "a failed role is recorded and the rest continue" (the Ruby side reads `crawl.json`), and the browser check in Task 4, Step 5.
2. **A password appears on a crawled page** (a profile form echoing it). It must not reach the bundle or the repo.
   → Task 4 "passwords never reach the bundle, argv or env"; Task 5 "a setup turn refuses a stored password".
3. **Setup started twice for one project.** The second start reopens the existing setup instead of creating a parallel branch.
   → Task 5 "starting twice reopens the same setup".
4. **The crawl is still running** when staff send the first message. The turn waits for the crawl rather than designing blind.
   → Task 5 "a turn waits while the crawl runs".
5. **Re-running setup after approval** (to refresh `master`). It starts a new setup on a fresh `wip/setup` from `master`.
   → Task 5 "a new run after approval starts from master".

---

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `db/migrate/20261103100000_add_design_setup.rb` | `design_setup_roles`, `design_setups`, `projects.design_app_url`, `projects.design_figma_urls`, project-level `chat_sessions`, the seed of the three phase prompts |
| `app/models/design_setup_role.rb`, `app/models/design_setup.rb` | Inputs, and one setup run |
| `app/controllers/workshop/design_setup_inputs_controller.rb` | Staff-only editing of inputs |
| `app/views/workshop/configuration/_designs_setup_inputs.html.erb` | The staff-only section of the Designs tab |
| `lib/designs_crawler/package.json`, `lib/designs_crawler/crawl.mjs` | The crawler |
| `app/jobs/designs/crawl_job.rb` | Runs the crawler and records the bundle |
| `app/services/designs/subject.rb` | `TaskSubject` and `SetupSubject`: what differs between a task turn and a setup turn |
| `app/controllers/workshop/design_setups_controller.rb` | The setup screen and its actions |
| `app/views/workshop/design_setups/show.html.erb` | The setup screen, reusing the Plan 2 partials |
| `lib/capistrano/tasks/designs_crawler.rake` | Installs the crawler and Chromium on the server |

**Modified files**

- `app/models/project.rb` — `has_many :design_setup_roles`, `has_many :design_setups`, `has_many_attached :design_materials`.
- `app/models/chat_session.rb` — task or project; purpose `designs_setup`.
- `app/jobs/designs/turn_job.rb` — runs through a subject.
- `app/services/designs/approval.rb` — setup approval.
- `app/views/workshop/configuration/_designs_tab.html.erb` — renders the staff section.
- `config/routes.rb`.

---

### Task 1: Can a headless browser run on Hostido? — a gate

No code. The answer decides where the crawler runs.

- [ ] **Step 1: Ask Kacper before touching the server.** Then, through `ssh` as in the server runner reference:

```bash
mkdir -p ~/flosis-crawler-spike ~/tmp && cd ~/flosis-crawler-spike
export TMPDIR=$HOME/tmp PLAYWRIGHT_BROWSERS_PATH=$HOME/.cache/ms-playwright
npm init -y >/dev/null && npm install playwright@1.48.2
npx playwright install chromium
node -e 'const { chromium } = require("playwright");
  (async () => { const b = await chromium.launch(); const p = await b.newPage();
    await p.goto("https://app.flosis.com/session/new"); await p.screenshot({ path: "shot.png" });
    console.log("ok", await p.title()); await b.close(); })().catch(e => { console.error(e); process.exit(1); });'
```

- [ ] **Step 2: Record the outcome here,** in a "Spike result" note under this task: the Chromium version, any missing shared libraries, and whether `shot.png` exists.
  - **If it works:** the crawler runs on the server, and Tasks 4–6 apply as written.
  - **If it fails** (missing `libnss3`, sandbox errors that `--no-sandbox` doesn't fix, noexec): stop. Write a short addendum, Plan 5b, for a staff-machine crawl. A `bin/designs-crawl` uses a one-time token from the setup screen, fetches the crawl input over HTTPS from a staff-only endpoint, runs the same `crawl.mjs` locally, and uploads the bundle. Tasks 2, 3 and 5 stay as they are either way.
- [ ] **Step 3: Remove `~/flosis-crawler-spike`.**

---

### Task 2: Setup inputs, for staff only

**Files:**
- Create: `db/migrate/20261103100000_add_design_setup.rb` (inputs part), `app/models/design_setup_role.rb`, `app/controllers/workshop/design_setup_inputs_controller.rb`, `app/views/workshop/configuration/_designs_setup_inputs.html.erb`
- Modify: `app/models/project.rb`, `app/views/workshop/configuration/_designs_tab.html.erb`, `config/routes.rb`
- Test: `test/controllers/workshop/design_setup_inputs_controller_test.rb`

**Interfaces:**
- Produces:
  - **`design_setup_roles`:**
    - `project_id` (not null)
    - `name` (string, not null, e.g. "Admin")
    - `login_url` (string, not null)
    - `username` (string, not null)
    - `password` (text, encrypted, not null)
    - `notes` (text)
    - `position` (integer, default 0)
    - timestamps
  - **On `projects`:** `design_app_url` (string) and `design_figma_urls` (json, nullable; the model defaults it to `[]`).
  - **`Project`:** `has_many :design_setup_roles, -> { order(:position, :id) }, dependent: :destroy` and `has_many_attached :design_materials`.
  - **`DesignSetupRole`** `encrypts :password`; it validates the presence of `name`, `login_url`, `username` and `password` (on create), and that `login_url` is http(s).
  - **Routes**, in `namespace :workshop`:

    ```ruby
    resource :design_setup_inputs, only: :update do
      post :add_role
      patch :update_role
      delete :remove_role
      delete :remove_material
    end
    ```

  - **`Workshop::DesignSetupInputsController`** carries a 404 gate unless `current_user.flosis_staff?`, and acts on `current_workshop_project`.
  - **The section** is rendered inside the Designs tab only for staff. It has:
    - an "APP URL" field;
    - a "FIGMA FILES" textarea, one URL per line;
    - a "MATERIALS" multiple file upload, with a list and remove buttons;
    - a "ROLES" list with name, login URL, username, a write-only password ("Leave blank to keep") and notes, with add and remove.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/design_setup_inputs_controller_test.rb
require "test_helper"

class Workshop::DesignSetupInputsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "a workspace admin who isn't staff neither sees nor changes setup inputs" do
    get workshop_configuration_path(tab: "designs")
    assert_select "body", text: /ROLES/, count: 0
    post add_role_workshop_design_setup_inputs_path, params: { role: { name: "Admin", login_url: "https://app.test/login", username: "a", password: "p" } }
    assert_response :not_found
    assert_equal 0, @project.design_setup_roles.count
  end

  test "staff add a role whose password is stored encrypted and never shown" do
    users(:one).update!(flosis_staff: true)
    post add_role_workshop_design_setup_inputs_path, params: { role: { name: "Admin", login_url: "https://app.test/login", username: "a", password: "s3cret-pass" } }
    role = @project.design_setup_roles.sole
    assert_equal "s3cret-pass", role.password
    assert_not_equal "s3cret-pass", DesignSetupRole.connection.select_value("SELECT password FROM design_setup_roles WHERE id = #{role.id}")
    get workshop_configuration_path(tab: "designs")
    assert_select "body", text: /s3cret-pass/, count: 0
  end

  test "staff set the app URL and Figma files" do
    users(:one).update!(flosis_staff: true)
    patch workshop_design_setup_inputs_path, params: { project: { design_app_url: "https://app.test", design_figma_urls: "https://figma.com/a\nhttps://figma.com/b" } }
    assert_equal %w[https://figma.com/a https://figma.com/b], @project.reload.design_figma_urls
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/design_setup_inputs_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the migration (the inputs part), the model, the controller, the section and the routes**

- [ ] **Step 4: Migrate and run the test to verify it passes**

Run: `bin/rails db:migrate && bin/rails test test/controllers/workshop/design_setup_inputs_controller_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261103100000_add_design_setup.rb db/schema.rb app/models/design_setup_role.rb app/models/project.rb app/controllers/workshop/design_setup_inputs_controller.rb app/views/workshop/configuration/_designs_setup_inputs.html.erb app/views/workshop/configuration/_designs_tab.html.erb config/routes.rb test/controllers/workshop/design_setup_inputs_controller_test.rb
git commit -m "feat: staff-only setup inputs — app URL, roles with encrypted passwords, Figma, materials"
```

---

### Task 3: A turn runs for a subject — a task, or a project's setup

**Files:**
- Create: `app/models/design_setup.rb`, `app/services/designs/subject.rb`
- Modify: `db/migrate/20261103100000_add_design_setup.rb` (setup part), `app/models/chat_session.rb`, `app/jobs/designs/turn_job.rb`
- Test: `test/services/designs/subject_test.rb`, `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Consumes: Plan 2's `TurnJob`; Plan 3's `LibraryEntry` and `Designs::Library`.
- Produces:
  - **Migration, setup part:**
    - `chat_sessions.task_id` becomes nullable (`change_column_null`, guarded);
    - `chat_sessions.project_id` (reference, nullable);
    - `design_setups`:
      - `project_id` (not null)
      - `phase` (string, not null, default `"design_system"`)
      - `status` (string, not null, default `"active"`; `active` or `approved`)
      - `started_by_id`
      - `crawl_dir`, `crawl_error` (strings), `crawled_at`, `approved_at`
      - timestamps
    - the seed of the `setup-design-system`, `setup-components` and `setup-designs` library entries.
  - **The phase prompts** (initial text, Flosis IP, editable later in the Library) each say:
    - which folders the phase owns, and that later phases must not undo earlier ones;
    - *design system* — read tokens from the app's CSS and theme files first and check them against the crawled computed styles; fonts and logos are copied, never approximated;
    - *components* — one component per real UI building block found in the app's views and partials, each with its guidelines and a preview page;
    - *designs* — each crawled page per role becomes a screen using only components, and `designs/contexts.json` gets the `permissions` dimension from the role names.
  - **`ChatSession`:**
    - `belongs_to :task, optional: true` and `belongs_to :project, optional: true`;
    - a validation that exactly one of the two is set;
    - `PURPOSES` gains `designs_setup`.
  - **`DesignSetup`:**
    - `PHASES = %w[design_system components designs].freeze`
    - `#next_phase! -> String | nil`
    - `#crawling? -> Boolean` (a crawl job is enqueued and `crawled_at` is still nil)
    - `scope :active`
  - **`Designs::Subject.for(chat_session) -> TaskSubject | SetupSubject`.** Both respond to:
    - `#project`, `#slug`
    - `#wip_branch` — `wip/<slug>` or `wip/setup`
    - `#base_branch_for_new_worktree` — `design/<slug>` if present else `master`; for setup, always `master`
    - `#preview_slot` — `wip/<slug>` or `wip/setup`
    - `#system_text`
      - for a task: Plan 3's composition;
      - for setup: the base prompt, the current phase's entry and the project section, plus a list of the read-only folders (crawl bundle, materials folder) and the Figma URLs.
    - `#forbidden_texts`
    - `#turn_message(request)`
    - `#api_key`
      - for a task: the project's own key;
      - for setup: `ENV["FLOSIS_DESIGNS_SETUP_API_KEY"]`.
    - `#missing_key_message`
    - `#add_dirs`
      - for a task: the app checkout;
      - for setup: the app checkout, `crawl_dir`, and the materials, which the job copies to `<workspace_dir>/design-materials/` before the turn.
    - `#secrets` — for setup it adds every role password.
  - **The concurrency key.** `Designs::TurnJob`'s key becomes `concurrency_key_for(session.task_id)` for a task session — unchanged, so Plan 4's Describe and Rename jobs still share it — and `"designs-setup-#{session.project_id}"` for a setup session.
  - **`Designs::TurnJob`** delegates every subject-specific value to `Designs::Subject.for(turn.chat_session)`. While `setup.crawling?`, it re-enqueues itself with `wait: 30.seconds` and leaves the turn `queued`, with a single `system` message `"Waiting for the crawl to finish…"`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/designs/subject_test.rb
require "test_helper"

class Designs::SubjectTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @setup = DesignSetup.create!(project: @project, started_by: users(:one))
    @session = ChatSession.create!(project: @project, workspace: @project.workspace, user: users(:one), purpose: "designs_setup",
                                   claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
  end

  test "a setup works on wip/setup from master, on Flosis's own key" do
    ENV["FLOSIS_DESIGNS_SETUP_API_KEY"] = "sk-flosis"
    subject = Designs::Subject.for(@session)
    assert_equal "wip/setup", subject.wip_branch
    assert_equal "master", subject.base_branch_for_new_worktree
    assert_equal "sk-flosis", subject.api_key
  ensure
    ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
  end

  test "the setup prompt follows the phase" do
    assert_includes Designs::Subject.for(@session).system_text, LibraryEntry.find_by!(key: "setup-design-system").current_version.body
    @setup.next_phase!
    assert_includes Designs::Subject.for(@session).system_text, LibraryEntry.find_by!(key: "setup-components").current_version.body
  end

  test "role passwords are secrets for the leak guard" do
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "s3cret-pass")
    assert_includes Designs::Subject.for(@session).secrets, "s3cret-pass"
  end

  test "a chat session belongs to a task or a project, never both or neither" do
    assert_not ChatSession.new(purpose: "designs_setup", workspace: @project.workspace, user: users(:one),
                               claude_session_id: "x", codebase_path: "/tmp").valid?
  end
end
```

In `test/jobs/designs/turn_job_test.rb` add "a setup turn commits to wip/setup on Flosis's key", using the fake Claude, and assert that the factory received `api_key: "sk-flosis"`. Also add "a turn waits while the crawl runs": `setup.update!(crawled_at: nil)` with a crawl marked as enqueued → `assert_enqueued_with(job: Designs::TurnJob)`, and the turn is still `queued`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/designs/subject_test.rb && bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the setup part of the migration, the models, `Designs::Subject`, and the `TurnJob` refactor**

The Plan 2 and Plan 3 turn tests must still pass unchanged.

- [ ] **Step 4: Migrate and run the tests to verify they pass**

Run: `bin/rails db:migrate && bin/rails test test/services/designs/subject_test.rb && bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261103100000_add_design_setup.rb db/schema.rb app/models/design_setup.rb app/models/chat_session.rb app/services/designs/subject.rb app/jobs/designs/turn_job.rb test/services/designs/subject_test.rb test/jobs/designs/turn_job_test.rb
git commit -m "feat: a design turn runs for a task or for a project's setup"
```

---

### Task 4: The crawler

**Files:**
- Create: `lib/designs_crawler/package.json`, `lib/designs_crawler/crawl.mjs`, `app/jobs/designs/crawl_job.rb`, `lib/capistrano/tasks/designs_crawler.rake`
- Modify: `config/application.rb` (`designs_crawler` joins the `autoload_lib` ignore list)
- Test: `test/jobs/designs/crawl_job_test.rb`

**Interfaces:**
- **`lib/designs_crawler/package.json`** is `{"private": true, "type": "module", "dependencies": {"playwright": "1.48.2"}}`, the version proven in Task 1.
- **`node crawl.mjs <outDir>`** reads JSON from stdin: `{ "baseUrl", "maxPagesPerRole": 40, "roles": [{ "name", "loginUrl", "username", "password", "notes" }] }`.
  - **Per role:**
    - a fresh browser context;
    - log in by filling the first `input[type=email], input[name*=email i], input[type=text]` with the username and the first `input[type=password]` with the password, then submitting the form;
    - success means the URL left the login page and no password field is visible.
  - **Crawl:** breadth-first over same-origin links from `baseUrl`, up to `maxPagesPerRole`, skipping logout, delete and sign-out links (by text or href) and any non-GET form.
  - **Per page:** `pages/<role>/<n>.png` (full page), and `pages/<role>/<n>.html` (DOM after the `input[type=password]` values are cleared and scripts removed).
  - **Bundle summary:** `crawl.json` holds `{ roles: [{ name, ok, error?, pages: [{ url, title, screenshot, dom }] }], styles: { colors: [top 24 computed colors], fonts: [families] } }`.
  - **Exit codes:** 0 when at least one role succeeded, 2 otherwise. It never prints credentials.
- **`Designs::CrawlJob.perform_later(design_setup_id)`:**
  - `queue_as :designs`;
  - the class attribute `runner`, a test seam that defaults to running `node <Rails.root>/lib/designs_crawler/crawl.mjs <dir>` via `Open3.capture3` with `stdin_data:` and a 20-minute timeout, from the folder set by `ENV["DESIGNS_CRAWLER_DIR"]`, where `node_modules` lives;
  - output under `<workspace_dir>/design-crawls/<UTC timestamp>/`;
  - on success it sets `crawl_dir` and `crawled_at` and posts a `system` message to the setup chat: `"Crawled <n> pages as <roles>."`, with a failed role named;
  - on failure it sets `crawl_error`.
- **`cap production setup:designs_crawler`** uploads `lib/designs_crawler` to `shared/designs_crawler`, then runs `npm ci`-equivalent `npm install` and `npx playwright install chromium` with `TMPDIR=$HOME/tmp` and `PLAYWRIGHT_BROWSERS_PATH=$HOME/.cache/ms-playwright`. `DESIGNS_CRAWLER_DIR` points there.

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/designs/crawl_job_test.rb
require "test_helper"

class Designs::CrawlJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:jira_project)
    @dir = Dir.mktmpdir("crawl")
    @project.update!(workspace_dir: @dir, design_app_url: "https://app.test")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "s3cret-pass")
    @setup = DesignSetup.create!(project: @project, started_by: users(:one))
  end

  teardown do
    Designs::CrawlJob.runner = nil
    FileUtils.remove_entry(@dir)
  end

  test "passwords never reach the bundle, argv or env" do
    seen = {}
    Designs::CrawlJob.runner = lambda do |argv:, env:, stdin:, out_dir:|
      seen = { argv: argv, env: env, stdin: stdin }
      File.write(File.join(out_dir, "crawl.json"), { roles: [ { name: "Admin", ok: true, pages: [] } ], styles: {} }.to_json)
      [ "", "", 0 ]
    end
    Designs::CrawlJob.perform_now(@setup.id)
    assert_includes JSON.parse(seen[:stdin])["roles"].first["password"], "s3cret-pass"
    assert_not_includes seen[:argv].join(" "), "s3cret-pass"
    assert_not_includes seen[:env].values.join(" "), "s3cret-pass"
    assert @setup.reload.crawled_at
    assert File.exist?(File.join(@setup.crawl_dir, "crawl.json"))
  end

  test "a failed role is recorded and the rest continue" do
    @project.design_setup_roles.create!(name: "Viewer", login_url: "https://app.test/login", username: "v", password: "other-pass")
    Designs::CrawlJob.runner = lambda do |out_dir:, **|
      File.write(File.join(out_dir, "crawl.json"), { roles: [
        { name: "Admin", ok: true, pages: [ { url: "https://app.test/", title: "Home" } ] },
        { name: "Viewer", ok: false, error: "login failed" }
      ], styles: {} }.to_json)
      [ "", "", 0 ]
    end
    Designs::CrawlJob.perform_now(@setup.id)
    assert @setup.reload.crawled_at
    assert_nil @setup.crawl_error
  end

  test "a crawl where every role failed records the error" do
    Designs::CrawlJob.runner = ->(**) { [ "", "all logins failed", 2 ] }
    Designs::CrawlJob.perform_now(@setup.id)
    assert_match(/all logins failed/, @setup.reload.crawl_error)
    assert_nil @setup.crawled_at
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/jobs/designs/crawl_job_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write `crawl.mjs`, `package.json`, the job, the cap task and the autoload ignore**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/jobs/designs/crawl_job_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 5: Verify the crawler for real, against local Gold**

1. In `lib/designs_crawler`: `npm install`, then `npx playwright install chromium`.
2. Run `bin/rails server`.
3. Pipe `{"baseUrl":"http://localhost:3000","maxPagesPerRole":10,"roles":[{"name":"Admin","loginUrl":"http://localhost:3000/session/new","username":"<dev user>","password":"<dev password>"}]}` into `node lib/designs_crawler/crawl.mjs tmp/crawl-check`.

Expected:
- exit 0;
- `tmp/crawl-check/crawl.json` lists up to 10 pages for Admin;
- the screenshots open;
- `grep -r "<dev password>" tmp/crawl-check` finds nothing.

Delete `tmp/crawl-check` afterwards.

- [ ] **Step 6: Commit**

```bash
git add lib/designs_crawler app/jobs/designs/crawl_job.rb lib/capistrano/tasks/designs_crawler.rake config/application.rb test/jobs/designs/crawl_job_test.rb
git commit -m "feat: crawl the running app as each role, with credentials only on stdin"
```

---

### Task 5: The setup screen — start, three phases, approve

**Files:**
- Create: `app/controllers/workshop/design_setups_controller.rb`, `app/views/workshop/design_setups/show.html.erb`
- Modify: `app/services/designs/approval.rb`, `app/views/workshop/configuration/_designs_setup_inputs.html.erb` (Start / Open setup), `config/routes.rb`, and the Plan 2 partials (`_chat`, `_preview`, `_top_bar`), which take a subject instead of an idea where needed
- Test: `test/controllers/workshop/design_setups_controller_test.rb`, `test/services/designs/approval_test.rb`

**Interfaces:**
- Consumes: Tasks 2–4; Plan 2's partials and `DesignTurn`; Plan 1's `Repo` and `Publisher`.
- Produces:
  - **Routes**, in `namespace :workshop`:

    ```ruby
    resource :design_setup, only: :show do
      post :start
      post :message
      post :next_phase
      post :approve
      get :chat
    end
    ```

    The helpers are `workshop_design_setup_path`, `start_workshop_design_setup_path`, and so on.
  - **`Workshop::DesignSetupsController`** has the staff 404 gate and acts on `current_workshop_project`.
    - **`start`:**
      - refuses without `FLOSIS_DESIGNS_SETUP_API_KEY`, with the global-constraint message;
      - reuses the project's `active` setup when one exists;
      - otherwise creates a `DesignSetup` and a `ChatSession(project:, purpose: "designs_setup")`, and enqueues `CrawlJob` when there are an app URL and roles;
      - redirects to `show`.
    - **`message`** works as Plan 2's, with the setup's session.
    - **`next_phase`** calls `next_phase!` and posts a `system` message `"Phase: <Components | Designs>."`.
    - **`approve`** calls `Designs::Approval.for_setup(project, user:).approve!`, which:
      - merges `wip/setup` into `master` and tags `approved/setup/<n>`;
      - pushes and publishes `master`;
      - marks the setup `approved`;
      - deletes the local `wip/setup` worktree, so the next run starts fresh from `master`.
  - **The screen** reuses the Plan 2 chat and preview partials.
    - Its top bar shows `Setup · <project> · Phase <n>/3: <phase>`, the waiting-commit count, "Open in new tab ↗", "Next phase" (phases 1–2) and "Approve setup → master" (phase 3).
    - A crawl status line reads "Crawling…", "Crawled <n> pages" or "Crawl failed: <error>".

- [ ] **Step 1: Write the failing tests**

```ruby
# test/controllers/workshop/design_setups_controller_test.rb
require "test_helper"

class Workshop::DesignSetupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(designs_enabled: true, design_repo: "a/b", design_repo_token: "t", design_repo_status: "ready",
                     design_preview_token: "t0k", design_app_url: "https://app.test")
    @project.design_setup_roles.create!(name: "Admin", login_url: "https://app.test/login", username: "a", password: "p4ssword")
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
    ENV["FLOSIS_DESIGNS_SETUP_API_KEY"] = "sk-flosis"
  end

  teardown { ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY") }

  test "a workspace admin who isn't staff gets a 404" do
    post start_workshop_design_setup_path
    assert_response :not_found
  end

  test "staff start a setup, which begins with the crawl" do
    users(:one).update!(flosis_staff: true)
    assert_enqueued_with(job: Designs::CrawlJob) { post start_workshop_design_setup_path }
    assert_redirected_to workshop_design_setup_path
    assert_equal "design_system", @project.design_setups.active.sole.phase
  end

  test "starting twice reopens the same setup" do
    users(:one).update!(flosis_staff: true)
    post start_workshop_design_setup_path
    post start_workshop_design_setup_path
    assert_equal 1, @project.design_setups.active.count
  end

  test "without Flosis's setup key nothing starts" do
    users(:one).update!(flosis_staff: true)
    ENV.delete("FLOSIS_DESIGNS_SETUP_API_KEY")
    post start_workshop_design_setup_path
    assert_equal 0, @project.design_setups.count
    assert_match(/FLOSIS_DESIGNS_SETUP_API_KEY/, flash[:alert])
  end

  test "the phases advance in order" do
    users(:one).update!(flosis_staff: true)
    post start_workshop_design_setup_path
    post next_phase_workshop_design_setup_path
    post next_phase_workshop_design_setup_path
    assert_equal "designs", @project.design_setups.active.sole.phase
  end
end
```

In `test/services/designs/approval_test.rb` add:
- **"approving a setup merges wip/setup into master and tags approved/setup/1"** — a real repo: commit on `wip/setup`, approve, and the remote `master` contains the file.
- **"a new run after approval starts from master"** — approve, start again: the new worktree's HEAD equals `master`.
- **"a setup turn refuses a stored password"** — add it to `test/jobs/designs/turn_job_test.rb`: the fake Claude writes a role's password into `designs/a.html`, and the turn fails with "contains a stored credential".

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/workshop/design_setups_controller_test.rb && bin/rails test test/services/designs/approval_test.rb && bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the routes, the controller, the screen, `Approval.for_setup` and the partial changes**

- [ ] **Step 4: Run the tests to verify they pass**

Run the same three files.
Expected: PASS, the Plan 2–4 tests included.

- [ ] **Step 5: Commit**

```bash
git add config/routes.rb app/controllers/workshop/design_setups_controller.rb app/views/workshop/design_setups app/views/workshop/designs app/services/designs/approval.rb app/views/workshop/configuration/_designs_setup_inputs.html.erb test/controllers/workshop/design_setups_controller_test.rb test/services/designs/approval_test.rb test/jobs/designs/turn_job_test.rb
git commit -m "feat: the setup run — crawl, three reviewed phases on wip/setup, approve into master"
```

---

### Task 6: Production — stop and ask Kacper before each outward step

- [ ] **Step 1: Environment.** Add `FLOSIS_DESIGNS_SETUP_API_KEY` (Flosis's own API key, never a subscription login) and `DESIGNS_CRAWLER_DIR=<shared>/designs_crawler` to `.env.production`, then run `cap production setup:upload_env`.
- [ ] **Step 2: Install the crawler.** Run `cap production setup:designs_crawler`, the path the Task 1 spike proved. If the spike failed, do Plan 5b instead.
- [ ] **Step 3: Deploy.** Push first, then deploy right after a 5-minute automation tick.
- [ ] **Step 4: Run setup on Gold.**
  1. In Gold's Designs tab (as staff), enter app.flosis.com and a role per permission level. Use test accounts created for this, never real people's passwords.
  2. Start setup and wait for "Crawled n pages".
  3. Run the three phases, reviewing each in the preview.
  4. Approve.
  5. `master` now holds Gold's design system, components and current screens, and every task branch starts from it.
