# Workshop Designs — Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a Workshop project a design repo that Flosis can create from a template on GitHub, branch, commit to behind a leak guard, merge approvals into and publish to a preview host. Add the shared git and API-key plumbing every later Designs plan builds on.

**Architecture:**
- Plain service objects under `Designs::` drive the git CLI through one runner, `GitRunner`. It authenticates with `GIT_ASKPASS`, so no token is ever written to `.git/config` or put on a command line.
- Each project keeps one clone, always on `master`, plus a worktree per working branch, all inside its own folder.
- Publishing exports a branch with `git archive` into a per-project, per-slot folder of a static document root, then swaps it in atomically.
- The repo opens in a browser with no build step. A small runtime script resolves `<x-include>` components and contexts, and a vendored Tailwind browser build styles the pages.

**Tech Stack:** Rails 8.1, Ruby 3.4.1, Minitest with fixtures, the git CLI (via Open3), Capistrano, Apache on Hostido, and `@tailwindcss/browser@4.2.1` (vendored; the same version as `tailwindcss-ruby` 4.2.1 in `Gemfile.lock`). PostgreSQL in development and test, **MySQL (MariaDB) in production**.

**Spec:** `docs/superpowers/specs/2026-10-30-workshop-designs-design.md`

## Where this plan sits

The spec ships as five plans. Each one delivers working, tested software on its own. Each later plan is written after the one before it has landed, against the code as it then is.

1. **Foundation (this plan)**
   - design settings on the project;
   - git plumbing, the leak guard, preview publishing;
   - the repo template and its runtime;
   - the Designs configuration tab;
   - the API key under `--bare`;
   - tokenless app-repo checkouts.
2. **Designs sessions**
   - the Designs screen (top bar, chat, preview, contexts);
   - the background turn runner;
   - approval (`wip/<KEY>` → `design/<KEY>` → `master`, tag `approved/<KEY>/<n>`) and reopening.
3. **Library and style packs**
   - the Flosis staff flag;
   - the staff-only library (prompts, skills, style packs, versions) and the commit → version record;
   - the style pack choice per project;
   - the first style pack.
4. **Pipeline handoffs and Jira**
   - "Start with designs", "Continue to Details", the current-description rule;
   - project-aware Briefing and Details chats;
   - Jira Web links on approval;
   - the branch rename when the Jira issue appears.
5. **Setup run**
   - the Hostido headless-browser check;
   - setup inputs (credentials per role, Figma, materials) and the crawl;
   - project-level sessions;
   - the three phases on `wip/setup`, run on Flosis's own key.

## Global Constraints

- **Production is MySQL**, and it commits DDL outside the migration transaction. Guard every `add_column` with `column_exists?` and every `add_index` with `index_exists?`.
- **The local `pg` gem segfaults on the full suite.** Run test files one at a time (`bin/rails test test/path/file_test.rb`). The whole suite is verified on the server.
- **Commit messages carry no `Co-Authored-By` and no `Claude-Session` trailer.**
- **`%w[]` arrays take no comments.** A `#` line inside one becomes an entry.
- **Git tokens stay out of everything persistent or visible.** A token never appears in `.git/config`, a remote URL, a command-line argument, a log line or an exception message. Git authenticates only through `GIT_ASKPASS` (`bin/git-askpass`), which reads `FLOSIS_GIT_TOKEN` from the environment.
- **Allowed paths.** A commit to a design repo may touch only `README.md`, `index.html`, `design_system/`, `components/`, `designs/` and `runtime/`.
- **Branches:**
  - `master`;
  - `design/<KEY>` (approved);
  - `wip/<KEY>` (work in progress);
  - `wip/setup`.
  `<KEY>` is the Jira key, or `task-<id>` before the issue exists.
- **Approval tags** are `approved/<KEY>/<n>`, with n counting from 1, on the approval's merge commit.
- **Commit identity.** All commits and merges are authored as `Flosis <designs@flosis.com>`.
- **Preview URLs** are `<DESIGNS_PREVIEW_URL>/<project preview token>/<slot>/<path>`, plus `?ctx=<value>,<value>` when contexts are given. The slots are `master`, `<KEY>`, `wip/<KEY>` and `wip/setup`.
- **Published file modes:** files 0644, folders 0755. Apache on Hostido cannot read 0640.
- **The legacy Elvium checkout** (`Project#legacy_elvium?`, `~/work/elvium`) is never touched.
- **Workshop UI copy is English** and uses the existing `clar-` classes.
- **HR files stay untouched.**

## Review Focus

1. **An empty GitHub repo** (just created, with no branches) is the state every project starts in. Cloning it and pushing the first `master` must work.
   → Task 6 "ensure_clone! clones an empty remote", Task 10 "an empty repo gets master from the template".
2. **A design-repo token that can read but not push.** Initialization must end with `design_repo_status: "error"` and git's message, without the token, and the tab must show it.
   → Task 10 "records a push failure without the token", Task 11 "a failed setup shows git's message".
3. **Two jobs working on one project's repo at once** (an initialization and a publish) must not collide on git's lock files.
   → Task 6 "synchronize serializes concurrent callers".
4. **Rotating the preview token** must kill every old link and keep the previews available under the new token.
   → Task 8 "rotate_token! moves the previews and kills the old path".
5. **Changing the design repo after initialization** must not push the old clone's history into the new repo.
   → Task 6 "ensure_clone! re-clones when the repo changes".

---

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `db/migrate/20261030120000_add_design_settings_to_projects.rb` | The design columns on `projects` |
| `bin/git-askpass` | Answers git's credential prompts from the environment |
| `app/services/git_runner.rb` | Runs git with askpass authentication and scrubs the token from errors |
| `app/services/designs/branch_names.rb` | Branch and approval-tag naming |
| `app/services/designs/repo.rb` | Clone, worktrees, staging, commits, pushes, merges, tags, renames; one lock per project |
| `app/services/designs/leak_guard.rb` | Refuses paths outside the allowed six, library passages and stored credentials |
| `app/services/designs/committer.rb` | Stage → guard → commit, or discard |
| `app/services/designs/publisher.rb` | Exports a branch into the preview document root; builds preview URLs; rotates the token |
| `app/services/designs/template.rb` | Renders `lib/designs_template` into a directory for one project |
| `lib/designs_template/**` | The design repo template and its browser runtime |
| `app/jobs/designs/initialize_repo_job.rb` | Creates `master` from the template, pushes and publishes it |
| `app/views/workshop/configuration/_designs_tab.html.erb` | The Designs tab |
| `bin/designs-preview` | Development static server for the preview root |
| `test/test_helpers/design_repo_test_helper.rb` | Bare "GitHub" remotes and configured projects for tests |

**Modified files**

- `config/application.rb` — `designs_template` joins the `autoload_lib` ignore list.
- `app/models/project.rb`, `app/services/project_credentials.rb` — design settings.
- `app/jobs/project_repo_checkout_job.rb` — tokenless clone and pull.
- `app/services/claude_cli_service.rb` — the `api_key:` option.
- `app/controllers/workshop/configuration_controller.rb`, `app/views/workshop/configuration/show.html.erb`, `config/routes.rb` — the Designs tab, plus the checkout enqueued on GitHub save.
- `lib/capistrano/tasks/setup.rake`, `config/deploy.rb` — the preview host's `.htaccess`.
- `test/test_helper.rb` — requires the design repo helper.

---

### Task 1: Design settings on the project

**Files:**
- Create: `db/migrate/20261030120000_add_design_settings_to_projects.rb`
- Modify: `app/models/project.rb`, `app/services/project_credentials.rb`
- Test: `test/models/project_design_settings_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - Columns on `projects`:
    - `designs_enabled` (boolean, default false, not null)
    - `design_repo` (string)
    - `design_repo_token` (text, encrypted)
    - `design_base_kit` (string, default `"tailwind4"`, not null)
    - `design_preview_token` (string, unique index)
    - `design_repo_status` (string: nil, `"initializing"`, `"ready"`, `"error"`)
    - `design_repo_error` (string)
  - `Project::DESIGN_BASE_KITS = %w[tailwind4 plain].freeze`
  - `Project#ensure_design_preview_token! -> String`
  - `ProjectCredentials#design_repo -> String | nil`, `#design_repo_token -> String | nil`, `#design_repo_configured? -> Boolean`

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/project_design_settings_test.rb
require "test_helper"

class ProjectDesignSettingsTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "a new project has Designs off and the Tailwind v4 kit" do
    project = Project.new(name: "New", workspace: workspaces(:one), color: "#3B82F6")
    assert_equal false, project.designs_enabled
    assert_equal "tailwind4", project.design_base_kit
  end

  test "the base kit must be one Flosis supports" do
    @project.design_base_kit = "bootstrap5"
    assert_not @project.valid?
    assert_includes @project.errors[:design_base_kit], "is not included in the list"
  end

  test "the design repo is owner/name or blank" do
    @project.design_repo = "https://github.com/acme/designs"
    assert_not @project.valid?
    @project.design_repo = "acme/designs"
    assert @project.valid?
    @project.design_repo = ""
    assert @project.valid?
  end

  test "the design repo token is encrypted at rest" do
    @project.update!(design_repo_token: "ghp_secret")
    raw = Project.connection.select_value("SELECT design_repo_token FROM projects WHERE id = #{@project.id}")
    assert_not_equal "ghp_secret", raw
    assert_equal "ghp_secret", @project.reload.design_repo_token
  end

  test "ensure_design_preview_token! makes one long random token and keeps it" do
    token = @project.ensure_design_preview_token!
    assert_match(/\A[a-zA-Z0-9]{32}\z/, token)
    assert_equal token, @project.reload.ensure_design_preview_token!
  end

  test "the design repo token never falls back to another credential" do
    @project.update!(github_token: "app-repo-token", design_repo: "acme/designs", design_repo_token: nil)
    creds = ProjectCredentials.new(@project)
    assert_nil creds.design_repo_token
    assert_not creds.design_repo_configured?

    @project.update!(design_repo_token: "design-token")
    assert creds.design_repo_configured?
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/project_design_settings_test.rb`
Expected: FAIL with `unknown attribute 'designs_enabled'` / `NoMethodError`.

- [ ] **Step 3: Write the migration and the model changes**

- **Migration.** Use `up`/`down`. Every `add_column` is guarded by `column_exists?`, and `add_index :projects, :design_preview_token, unique: true` by `index_exists?`. Put a header comment that explains the MySQL guard, like `20261028160000_add_show_in_workshop_to_projects.rb`.
- **`Project`:**
  - `encrypts :design_repo_token`
  - `DESIGN_BASE_KITS`
  - `validates :design_base_kit, inclusion: { in: DESIGN_BASE_KITS }`
  - `validates :design_repo, format: { with: %r{\A[\w.-]+/[\w.-]+\z} }, allow_blank: true`
  - `ensure_design_preview_token!` returns the stored token, or stores `SecureRandom.alphanumeric(32)` with `update_column` and returns it.
- **`ProjectCredentials`:**
  - `design_repo` and `design_repo_token` read the project column only, with no fallback. Say why in a comment: the design repo token has write access, and borrowing the app repo's would push with the wrong scope.
  - `design_repo_configured?` is true when both are present.

- [ ] **Step 4: Migrate and run the test to verify it passes**

Run: `bin/rails db:migrate && bin/rails test test/models/project_design_settings_test.rb`
Expected: PASS (6 runs). `db/schema.rb` shows the seven new columns and the index.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261030120000_add_design_settings_to_projects.rb db/schema.rb app/models/project.rb app/services/project_credentials.rb test/models/project_design_settings_test.rb
git commit -m "feat: a project carries its design repo, kit and preview token"
```

---

### Task 2: Git that authenticates without writing the token anywhere

**Files:**
- Create: `bin/git-askpass` (executable), `app/services/git_runner.rb`
- Test: `test/services/git_runner_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `GitRunner.run!(*args, chdir:, token: nil) -> String` — returns stdout.
    - It runs `git -c credential.helper= <args>` with `GitRunner.env(token)`.
    - On a non-zero exit it raises `GitRunner::Error` with the message `"git <first arg> failed: <stderr>"`, with every occurrence of the token replaced by `[FILTERED]`.
  - `GitRunner.env(token) -> Hash{String => String}` — always sets `GIT_TERMINAL_PROMPT=0`. With a token it also sets `GIT_ASKPASS=<Rails.root>/bin/git-askpass`, `FLOSIS_GIT_TOKEN=<token>` and `FLOSIS_GIT_USERNAME=x-access-token`.
  - `GitRunner.github_url(repo) -> String` — `"https://github.com/#{repo}.git"`.
  - `GitRunner::Error < StandardError`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/git_runner_test.rb
require "test_helper"

class GitRunnerTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir("git-runner") }
  teardown { FileUtils.remove_entry(@dir) }

  test "returns git's output" do
    assert_match(/\Agit version /, GitRunner.run!("--version", chdir: @dir))
  end

  test "a failing command raises with git's message and without the token" do
    error = assert_raises(GitRunner::Error) do
      GitRunner.run!("not-a-command-ghp_SECRET123", chdir: @dir, token: "ghp_SECRET123")
    end
    assert_match(/not a git command/, error.message)
    assert_not_includes error.message, "ghp_SECRET123"
  end

  test "the token travels in the environment, never in the arguments" do
    env = GitRunner.env("ghp_SECRET123")
    assert_equal "ghp_SECRET123", env["FLOSIS_GIT_TOKEN"]
    assert_equal "0", env["GIT_TERMINAL_PROMPT"]
    assert File.executable?(env["GIT_ASKPASS"])
  end

  test "the askpass script answers the username and the password prompts" do
    env = GitRunner.env("ghp_SECRET123")
    user, = Open3.capture2(env, env["GIT_ASKPASS"], "Username for 'https://github.com': ")
    pass, = Open3.capture2(env, env["GIT_ASKPASS"], "Password for 'https://x-access-token@github.com': ")
    assert_equal "x-access-token", user.chomp
    assert_equal "ghp_SECRET123", pass.chomp
  end

  test "github_url carries no credentials" do
    assert_equal "https://github.com/acme/designs.git", GitRunner.github_url("acme/designs")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/git_runner_test.rb`
Expected: FAIL with `uninitialized constant GitRunner`.

- [ ] **Step 3: Write `bin/git-askpass` and `GitRunner`**

`bin/git-askpass` is exactly this. Run `chmod 755` before `git add` so git records the executable bit.

```sh
#!/bin/sh
# Answers git's credential prompts from the environment, so a token never has
# to sit in a remote URL, in .git/config or on a command line. See GitRunner.
case "$1" in
  Username*) printf '%s\n' "${FLOSIS_GIT_USERNAME:-x-access-token}" ;;
  *) printf '%s\n' "$FLOSIS_GIT_TOKEN" ;;
esac
```

`GitRunner` uses `Open3.capture3(env, "git", "-c", "credential.helper=", *args, chdir: chdir.to_s)`. The empty `credential.helper` keeps a machine-wide helper (osxkeychain locally) from answering instead of the askpass script.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/git_runner_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 5: Commit**

```bash
git add bin/git-askpass app/services/git_runner.rb test/services/git_runner_test.rb
git commit -m "feat: git authenticates through askpass, so tokens never touch disk or argv"
```

---

### Task 3: App-repo checkouts without a token, queued when GitHub is saved

**Files:**
- Modify: `app/jobs/project_repo_checkout_job.rb`, `app/controllers/workshop/configuration_controller.rb` (`save_integration`)
- Test: `test/jobs/project_repo_checkout_job_test.rb`, `test/controllers/workshop/configuration_controller_test.rb`

**Interfaces:**
- Consumes: `GitRunner.run!`, `GitRunner.github_url` (Task 2).
- Produces:
  - The test seam changes from `->(cmd, chdir:)` to `ProjectRepoCheckoutJob.stub_git = ->(args, chdir:, token:)`. `args` are the git arguments without the leading `"git"`.
  - Saving the GitHub integration enqueues `ProjectRepoCheckoutJob.perform_later(project.id)` when `ProjectCredentials#github_configured?`.

- [ ] **Step 1: Update the test seam and write the failing tests**

In `test/jobs/project_repo_checkout_job_test.rb`:

- Change `with_git_capture` to record keyword arguments:

  ```ruby
  ProjectRepoCheckoutJob.stub_git = ->(args, chdir:, token: nil) { calls << { args: args, chdir: chdir, token: token }; true }
  ```

- In "clones when no checkout exists", change the assertion to `calls.any? { |c| c[:args].first == "clone" }`.
- Add:

```ruby
  test "clones a URL that carries no token, and hands the token over separately" do
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      clone = calls.find { |c| c[:args].first == "clone" }
      assert_equal "https://github.com/acme/app.git", clone[:args][1]
      assert_equal "ght", clone[:token]
      assert calls.none? { |c| c[:args].join(" ").include?("ght") }
    end
  end

  # Checkouts made before this change hold the token in their remote URL.
  # Rewriting it before every pull is what cleans them up.
  test "an existing checkout gets a tokenless remote before it pulls" do
    FileUtils.mkdir_p(File.join(@project.repo_checkout_path, ".git"))
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert_equal [ %w[remote set-url origin https://github.com/acme/app.git], %w[pull --ff-only] ],
                   calls.map { |c| c[:args] }
    end
  end
```

In `test/controllers/workshop/configuration_controller_test.rb` add:

```ruby
  test "saving the GitHub integration queues a checkout of the project's repo" do
    assert_enqueued_with(job: ProjectRepoCheckoutJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: {
        tab: "integrations", integration: "github",
        project: { github_repo: "acme/app", github_token: "ght" }
      }
    end
  end

  test "saving GitHub without a token queues no checkout" do
    @project.update!(github_token: nil)
    assert_no_enqueued_jobs(only: ProjectRepoCheckoutJob) do
      patch workshop_configuration_path, params: {
        tab: "integrations", integration: "github", project: { github_repo: "acme/app", github_token: "" }
      }
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/jobs/project_repo_checkout_job_test.rb && bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: FAIL. The clone URL still carries `ght@`, the set-url call is missing, and no job is enqueued.

- [ ] **Step 3: Change the job and the controller**

- **The job:**
  - Clone with `run_git(["clone", GitRunner.github_url(repo), checkout], chdir: parent, token: token)`.
  - On an existing checkout, run `["remote", "set-url", "origin", GitRunner.github_url(repo)]` and then `["pull", "--ff-only"]` with the token.
  - `run_git(args, chdir:, token: nil)` calls the stub when it is set, otherwise `GitRunner.run!(*args, chdir:, token:)`.
  - Update the header comment, which says "Enqueued when the GitHub integration is saved", so it is true.
- **The controller:** at the end of `save_integration`, add `ProjectRepoCheckoutJob.perform_later(project.id) if params[:integration].to_s == "github" && ProjectCredentials.new(project).github_configured?`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/jobs/project_repo_checkout_job_test.rb && bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS. The legacy-Elvium and error-status tests still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/project_repo_checkout_job.rb app/controllers/workshop/configuration_controller.rb test/jobs/project_repo_checkout_job_test.rb test/controllers/workshop/configuration_controller_test.rb
git commit -m "fix: app-repo checkouts keep the token out of .git/config, and saving GitHub starts one"
```

---

### Task 4: Claude runs on a given API key, never on the server's login

**Files:**
- Modify: `app/services/claude_cli_service.rb`
- Test: `test/services/claude_cli_service_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ClaudeCliService.new(codebase_path: nil, allowed_tools: nil, model: nil, mcp_config: nil, api_key: nil)`.
  - With `api_key`, the command includes `--bare` and the subprocess environment is `{ "ANTHROPIC_API_KEY" => api_key }`. `--bare` reads only `ANTHROPIC_API_KEY`, never OAuth or the keychain.
  - Without it, nothing changes.
  - Private `popen_args(cmd) -> Array` returns `[env, cmd]` or `[cmd]`, and both `run_claude` and `popen_streaming` use it.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "with an API key the CLI runs bare and gets the key in its environment" do
    service = ClaudeCliService.new(codebase_path: @codebase_path, api_key: "sk-ant-test")
    assert_includes service.send(:build_command, streaming: false), "--bare"
    assert_equal [ { "ANTHROPIC_API_KEY" => "sk-ant-test" }, [ "claude" ] ], service.send(:popen_args, [ "claude" ])
  end

  test "without an API key the command and the environment are unchanged" do
    service = ClaudeCliService.new(codebase_path: @codebase_path)
    refute_includes service.send(:build_command, streaming: false), "--bare"
    assert_equal [ [ "claude" ] ], service.send(:popen_args, [ "claude" ])
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/claude_cli_service_test.rb`
Expected: FAIL with `unknown keyword: :api_key`.

- [ ] **Step 3: Add `api_key:`**

- Store `@api_key`.
- In `build_command`, add `cmd << "--bare" if @api_key.present?` after `-p`.
- Change both `IO.popen(cmd, "r+", chdir: @codebase_path)` calls to `IO.popen(*popen_args(cmd), "r+", chdir: @codebase_path)`.
- Comment that `--bare` is what guarantees the server's own Claude login is never used for a run that was given a key.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/claude_cli_service_test.rb`
Expected: PASS. The existing `chdir_for` tests still pass.

- [ ] **Step 5: Commit**

```bash
git add app/services/claude_cli_service.rb test/services/claude_cli_service_test.rb
git commit -m "feat: ClaudeCliService can run on a given API key, bare, with no fallback to the server login"
```

---

### Task 5: Branch names

**Files:**
- Create: `app/services/designs/branch_names.rb`
- Test: `test/services/designs/branch_names_test.rb`

**Interfaces:**
- Consumes: `Task#external_reference`, `Task#id`.
- Produces:
  - `Designs::BranchNames::MASTER = "master"` and `SETUP = "wip/setup"`
  - `JIRA_KEY = /\A[A-Z][A-Z0-9_]+-\d+\z/`
  - `.slug(task) -> String` — the Jira key when `external_reference` matches `JIRA_KEY`, else `"task-#{task.id}"`
  - `.wip(task) -> "wip/<slug>"`
  - `.design(task) -> "design/<slug>"`
  - `.approval_tag(slug, n) -> "approved/<slug>/<n>"`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/designs/branch_names_test.rb
require "test_helper"

class Designs::BranchNamesTest < ActiveSupport::TestCase
  test "a Jira task is named after its key" do
    task = Task.new(id: 7, external_reference: "REC-142")
    assert_equal "REC-142", Designs::BranchNames.slug(task)
    assert_equal "wip/REC-142", Designs::BranchNames.wip(task)
    assert_equal "design/REC-142", Designs::BranchNames.design(task)
  end

  test "a task without a Jira issue is named after its id" do
    assert_equal "wip/task-7", Designs::BranchNames.wip(Task.new(id: 7, external_reference: nil))
  end

  test "anything that is not a Jira key falls back to the id" do
    assert_equal "task-7", Designs::BranchNames.slug(Task.new(id: 7, external_reference: "../master"))
  end

  test "approval tags number each approval of a task" do
    assert_equal "approved/REC-142/3", Designs::BranchNames.approval_tag("REC-142", 3)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/designs/branch_names_test.rb`
Expected: FAIL with `uninitialized constant Designs`.

- [ ] **Step 3: Write `Designs::BranchNames`** as a module with `module_function` methods.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/designs/branch_names_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/branch_names.rb test/services/designs/branch_names_test.rb
git commit -m "feat: design repo branch and approval-tag names"
```

---

### Task 6: The design repo

**Files:**
- Create: `app/services/designs/repo.rb`, `test/test_helpers/design_repo_test_helper.rb`
- Modify: `test/test_helper.rb` (add `require_relative "test_helpers/design_repo_test_helper"`)
- Test: `test/services/designs/repo_test.rb`

**Interfaces:**
- Consumes: `GitRunner` (Task 2); `ProjectCredentials#design_repo`, `#design_repo_token` (Task 1); `Project#ensure_workspace_dir!`.
- Produces — `Designs::Repo`:
  - **Construction and identity:**
    - `Designs::Repo.new(project, remote_url: nil)`. `remote_url` defaults to `Designs::Repo.remote_url_override || GitRunner.github_url(creds.design_repo)`.
    - The class attribute `remote_url_override` is the test seam.
    - `attr_reader :project, :remote_url`.
  - **Locations and locking:**
    - `#root -> Pathname` — `<workspace_dir>/design-repo`, a normal clone that stays on `master`.
    - `#worktrees_root -> Pathname` — `<workspace_dir>/design-worktrees`.
    - `#synchronize { }` — an exclusive `flock` on `<workspace_dir>/design-repo.lock`. It is re-entrant within one thread, and every other public method runs inside it.
  - **Clone:**
    - `#ensure_clone! -> Pathname`:
      - Clones when missing. An empty clone gets `git symbolic-ref HEAD refs/heads/master`, whatever `init.defaultBranch` says.
      - If `origin`'s URL differs from `remote_url`, it moves the clone (and the worktrees folder) aside to `*.replaced-<UTC timestamp>` and clones fresh.
      - Otherwise it runs `fetch --prune --tags origin`. When `origin/master` exists, it checks out `master` and resets it hard to `origin/master`.
    - `#initialized? -> Boolean` — `refs/remotes/origin/master` exists.
  - **Working branches:**
    - `#worktree!(branch, from: "master") -> Pathname` — `<worktrees_root>/<branch with "/" replaced by "__">`.
      - It uses the local branch if one exists, else `origin/<branch>`, else creates the branch from local `from`.
      - An existing worktree folder is returned as it is.
    - `#stage_all!(dir) -> Array<Designs::Repo::Change>` — `git add -A`, then one `Change` per staged path. `added_text` holds the `+` lines of `git diff --cached -U0 -- <path>` (without the `+++` header).
    - `Designs::Repo::Change = Data.define(:path, :added_text)`.
    - `#commit!(dir, message:) -> String | nil` — the new sha, or nil when nothing is staged. It uses the Flosis identity via `-c user.name=Flosis -c user.email=designs@flosis.com`.
    - `#discard!(dir)` — `reset --hard` plus `clean -fd`.
  - **Remote and refs:**
    - `#push!(*refs)` — `git push origin <refs>` with the token.
    - `#head(branch) -> String | nil` — the local branch's sha.
    - `#commits_ahead(branch, base: "master") -> Integer`.
    - `#point!(branch, to:)` — `git branch -f`.
  - **Merges, tags and renames:**
    - `#merge_into_master!(branch, message:) -> String` — in `root`, on the local `master` as it stands, `merge --no-ff` with the Flosis identity. Returns the new `master` sha. On conflict it runs `merge --abort` and raises `Designs::Repo::Conflict`. It never pushes.
    - `#tag!(name, at:)`.
    - `#tags(pattern) -> Array<String>` — `git tag -l <pattern> --sort=v:refname`.
    - `#rename!(from, to)` — `git branch -m`, `git worktree move` when `from` has a worktree, push `to`, then `git push origin --delete from`.
  - `Designs::Repo::Conflict < StandardError`.
- Produces — `DesignRepoTestHelper`:
  - `with_design_remote(project = projects(:jira_project)) { |repo, remote| }`
  - `with_remote_url(url) { }`
  - `commit_files(repo, dir, files, message: "test") -> String`
  - `seed_master(repo, files = { "README.md" => "hi\n" }) -> String` (the `master` sha after the push)
  - `remote_branch_sha(remote, branch) -> String | nil`

- [ ] **Step 1: Write the test helper**

```ruby
# test/test_helpers/design_repo_test_helper.rb
# A bare repository on disk stands in for GitHub, so the git plumbing is tested
# for real without the network.
module DesignRepoTestHelper
  def with_design_remote(project = projects(:jira_project))
    dir = Dir.mktmpdir("design-remote")
    remote = File.join(dir, "remote.git")
    system("git", "init", "--bare", "--quiet", remote, exception: true)
    system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/master", exception: true)
    project.update!(workspace_dir: File.join(dir, "workspace"), design_repo: "acme/designs",
                    design_repo_token: "design-token", designs_enabled: true)
    yield Designs::Repo.new(project, remote_url: remote), remote
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def with_remote_url(url)
    Designs::Repo.remote_url_override = url
    yield
  ensure
    Designs::Repo.remote_url_override = nil
  end

  def commit_files(repo, dir, files, message: "test")
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), body)
    end
    repo.stage_all!(dir)
    repo.commit!(dir, message: message)
  end

  def seed_master(repo, files = { "README.md" => "hi\n" })
    repo.ensure_clone!
    commit_files(repo, repo.root, files)
    repo.push!("master")
    repo.ensure_clone!
    repo.head("master")
  end

  def remote_branch_sha(remote, branch)
    out, status = Open3.capture2("git", "-C", remote, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
    status.success? ? out.strip : nil
  end
end
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/services/designs/repo_test.rb
require "test_helper"

class Designs::RepoTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  test "ensure_clone! clones an empty remote, which is not initialized yet" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      assert repo.root.join(".git").exist?
      assert_not repo.initialized?
    end
  end

  test "the first commit on master reaches the remote and initializes the repo" do
    with_design_remote do |repo, remote|
      sha = seed_master(repo)
      assert_equal sha, remote_branch_sha(remote, "master")
      assert repo.initialized?
    end
  end

  test "no token ends up in the clone's config" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      assert_not_includes repo.root.join(".git/config").read, "design-token"
    end
  end

  test "a working branch starts from master and its commits reach the remote" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      sha = commit_files(repo, dir, { "designs/jobs.html" => "<p>jobs</p>" })
      repo.push!("wip/REC-1")
      assert_equal sha, remote_branch_sha(remote, "wip/REC-1")
      assert_equal 1, repo.commits_ahead("wip/REC-1")
    end
  end

  test "commit! returns nil when nothing changed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      repo.stage_all!(dir)
      assert_nil repo.commit!(dir, message: "nothing")
    end
  end

  test "stage_all! reports each path with the text it adds" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("README.md"), "hi\nnew line\n")
      changes = repo.stage_all!(dir)
      assert_equal [ "README.md" ], changes.map(&:path)
      assert_includes changes.first.added_text, "new line"
    end
  end

  test "discard! throws away uncommitted work" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("stray.html"), "x")
      repo.discard!(dir)
      assert_not dir.join("stray.html").exist?
    end
  end

  test "approving points the design branch at the work and merges it into master with a merge commit" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      wip = commit_files(repo, dir, { "designs/jobs.html" => "<p>jobs</p>" })
      repo.point!("design/REC-1", to: wip)
      merged = repo.merge_into_master!("design/REC-1", message: "Approve REC-1")
      repo.push!("design/REC-1", "master")
      assert_equal wip, remote_branch_sha(remote, "design/REC-1")
      assert_equal merged, remote_branch_sha(remote, "master")
      parents = GitRunner.run!("rev-list", "--parents", "-n", "1", merged, chdir: repo.root).split
      assert_equal 3, parents.size, "a merge commit has two parents"
    end
  end

  test "a conflicting merge raises Conflict and leaves master as it was" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/a.html" => "base\n" })
      dir = repo.worktree!("wip/REC-1")
      wip = commit_files(repo, dir, { "designs/a.html" => "from the task\n" })
      before = commit_files(repo, repo.root, { "designs/a.html" => "from master\n" })
      repo.point!("design/REC-1", to: wip)
      assert_raises(Designs::Repo::Conflict) { repo.merge_into_master!("design/REC-1", message: "Approve REC-1") }
      assert_equal before, repo.head("master")
      assert_empty GitRunner.run!("status", "--porcelain", chdir: repo.root)
    end
  end

  test "approval tags list in numeric order" do
    with_design_remote do |repo, _|
      sha = seed_master(repo)
      %w[1 2 10].each { |n| repo.tag!("approved/REC-1/#{n}", at: sha) }
      assert_equal %w[approved/REC-1/1 approved/REC-1/2 approved/REC-1/10], repo.tags("approved/REC-1/*")
    end
  end

  test "rename! moves a branch to its Jira name on the remote" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/task-5")
      sha = commit_files(repo, dir, { "designs/x.html" => "x" })
      repo.push!("wip/task-5")
      repo.rename!("wip/task-5", "wip/REC-9")
      assert_equal sha, remote_branch_sha(remote, "wip/REC-9")
      assert_nil remote_branch_sha(remote, "wip/task-5")
    end
  end

  test "ensure_clone! re-clones when the repo changes" do
    other_dir = Dir.mktmpdir("other-remote")
    with_design_remote do |repo, _|
      seed_master(repo)
      other = File.join(other_dir, "other.git")
      system("git", "init", "--bare", "--quiet", other, exception: true)
      moved = Designs::Repo.new(repo.project, remote_url: other)
      moved.ensure_clone!
      assert_not moved.initialized?, "the new repo starts empty, not with the old history"
    end
  ensure
    FileUtils.remove_entry(other_dir)
  end

  test "synchronize serializes concurrent callers" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      repos = 2.times.map { Designs::Repo.new(repo.project, remote_url: repo.remote_url) }
      log = Queue.new
      repos.each_with_index.map { |r, i|
        Thread.new { r.synchronize { log << [ :in, i ]; sleep 0.2; log << [ :out, i ] } }
      }.each(&:join)
      assert_equal %i[in out in out], 4.times.map { log.pop.first }
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/services/designs/repo_test.rb`
Expected: FAIL with `uninitialized constant Designs::Repo`.

- [ ] **Step 4: Write `Designs::Repo`** to the interface above.

- Every git call goes through `GitRunner.run!`. Network calls (`clone`, `fetch`, `push`) pass `token:`.
- Re-entrancy: keep a thread-local depth counter per lock path, so `synchronize` inside `synchronize` doesn't deadlock.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/services/designs/repo_test.rb`
Expected: PASS (13 runs).

- [ ] **Step 6: Commit**

```bash
git add app/services/designs/repo.rb test/test_helpers/design_repo_test_helper.rb test/test_helper.rb test/services/designs/repo_test.rb
git commit -m "feat: Designs::Repo — one clone per project, worktrees per branch, merges, tags, renames"
```

---

### Task 7: The leak guard and the guarded commit

**Files:**
- Create: `app/services/designs/leak_guard.rb`, `app/services/designs/committer.rb`
- Test: `test/services/designs/leak_guard_test.rb`, `test/services/designs/committer_test.rb`

**Interfaces:**
- Consumes: `Designs::Repo::Change`, `#stage_all!`, `#commit!`, `#discard!` (Task 6).
- Produces:
  - `Designs::LeakGuard::ALLOWED_FILES = %w[README.md index.html].freeze`
  - `ALLOWED_DIRS = %w[design_system/ components/ designs/ runtime/].freeze`
  - `PASSAGE_WORDS = 12`
  - `Designs::LeakGuard.new(forbidden_texts: [], secrets: [])` and `#check(changes) -> Array<Designs::LeakGuard::Violation>`
  - `Violation = Data.define(:path, :reason)`. The reasons are exactly:
    - `"is outside the design repo's allowed folders"`
    - `"contains a passage from the Flosis library"`
    - `"contains a stored credential"`
  - `Designs::Committer.new(repo, guard)` and `#commit!(dir, message:) -> Designs::Committer::Result`
  - `Result = Data.define(:sha, :violations)` with `#ok? -> Boolean` (no violations)

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/designs/leak_guard_test.rb
require "test_helper"

class Designs::LeakGuardTest < ActiveSupport::TestCase
  def change(path, text = "x") = Designs::Repo::Change.new(path: path, added_text: text)

  test "files in the six allowed places pass" do
    paths = %w[README.md index.html design_system/README.md components/button/button.html designs/jobs.html runtime/flosis.js]
    assert_empty Designs::LeakGuard.new.check(paths.map { change(_1) })
  end

  test "anything else is refused, tool configuration included" do
    %w[.claude/skills/style.md notes.md CLAUDE.md .github/workflows/x.yml designs_extra/a.html].each do |path|
      assert_equal [ "is outside the design repo's allowed folders" ],
                   Designs::LeakGuard.new.check([ change(path) ]).map(&:reason), "#{path} must be refused"
    end
  end

  test "a twelve-word passage from the library is refused however it is spaced or cased" do
    library = "Always pair the display serif with a quiet grotesk and keep body copy at sixteen pixels."
    added = "<p>ALWAYS pair the display serif with a quiet grotesk,\n and keep body copy at sixteen pixels</p>"
    violations = Designs::LeakGuard.new(forbidden_texts: [ library ]).check([ change("designs/a.html", added) ])
    assert_equal [ "contains a passage from the Flosis library" ], violations.map(&:reason)
  end

  test "eleven shared words are not a passage" do
    library = "one two three four five six seven eight nine ten eleven twelve"
    added = "one two three four five six seven eight nine ten eleven"
    assert_empty Designs::LeakGuard.new(forbidden_texts: [ library ]).check([ change("designs/a.html", added) ])
  end

  test "a stored credential is refused, and the violation does not repeat it" do
    violations = Designs::LeakGuard.new(secrets: [ "ghp_SECRET123" ]).check([ change("designs/a.html", "token=ghp_SECRET123") ])
    assert_equal [ "contains a stored credential" ], violations.map(&:reason)
    assert_not_includes violations.inspect, "ghp_SECRET123"
  end

  test "blank and short secrets are ignored" do
    assert_empty Designs::LeakGuard.new(secrets: [ nil, "", "abc" ]).check([ change("designs/a.html", "abc") ])
  end
end
```

```ruby
# test/services/designs/committer_test.rb
require "test_helper"

class Designs::CommitterTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  test "a clean change is committed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("index.html"), "<h1>Hi</h1>")
      result = Designs::Committer.new(repo, Designs::LeakGuard.new).commit!(dir, message: "Turn 1")
      assert result.ok?
      assert_equal repo.head("wip/REC-1"), result.sha
    end
  end

  test "a refused change is thrown away and nothing is committed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      FileUtils.mkdir_p(dir.join(".claude"))
      File.write(dir.join(".claude/skill.md"), "secret sauce")
      result = Designs::Committer.new(repo, Designs::LeakGuard.new).commit!(dir, message: "Turn 1")
      assert_not result.ok?
      assert_nil result.sha
      assert_equal before, repo.head("wip/REC-1")
      assert_not dir.join(".claude").exist?
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/designs/leak_guard_test.rb && bin/rails test test/services/designs/committer_test.rb`
Expected: FAIL with `uninitialized constant Designs::LeakGuard`.

- [ ] **Step 3: Write `Designs::LeakGuard` and `Designs::Committer`**

- **Passage rule.** Lower-case each text and split it into words with `scan(/[[:alnum:]]+/)`. Build the set of every run of `PASSAGE_WORDS` consecutive words from `forbidden_texts`. A change violates the rule when any 12-word run of its `added_text` is in that set.
- **Secrets.** A secret counts only when it is at least 8 characters long after stripping.
- **Committer.** It runs `stage_all!`, then `check`. With violations it runs `discard!` and returns `Result.new(sha: nil, violations:)`; otherwise it commits.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/designs/leak_guard_test.rb && bin/rails test test/services/designs/committer_test.rb`
Expected: PASS (8 runs).

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/leak_guard.rb app/services/designs/committer.rb test/services/designs/leak_guard_test.rb test/services/designs/committer_test.rb
git commit -m "feat: the leak guard refuses stray paths, library passages and credentials before any commit"
```

---

### Task 8: Publishing to the preview host

**Files:**
- Create: `app/services/designs/publisher.rb`
- Test: `test/services/designs/publisher_test.rb`

**Interfaces:**
- Consumes: `Designs::Repo#head`, `#root`, `#synchronize` (Task 6); `Project#ensure_design_preview_token!` (Task 1).
- Produces:
  - `Designs::Publisher.root -> Pathname` — `ENV["DESIGNS_PREVIEW_ROOT"]`, else `Rails.root.join("tmp/designs_preview")`.
  - `Designs::Publisher.base_url -> String` — `ENV["DESIGNS_PREVIEW_URL"]`, else `"http://localhost:3100"`.
  - `Designs::Publisher::SLOT = %r{\A(master|wip/setup|wip/[A-Za-z0-9_-]+|[A-Za-z0-9_-]+)\z}`.
  - `Designs::Publisher.new(project, repo)`.
  - `#publish!(branch, slot) -> Pathname`:
    - It raises `ArgumentError` for a slot that doesn't match `SLOT`.
    - It exports `repo.head(branch)` with `git archive --format=tar -o <tmp>.tar <sha>` and extracts it into `<root>/<token>/.staging-<hex>`.
    - It sets every folder (the token folder included) to 0755 and every file to 0644.
    - It moves the current slot aside to `.old-<hex>`, renames staging into place, and removes the old copy.
  - `#url(slot, path = "index.html", ctx: []) -> String`.
  - `#rotate_token! -> String` — inside `repo.synchronize` it renames `<root>/<old token>` to `<root>/<new token>` and stores the new token.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/designs/publisher_test.rb
require "test_helper"

class Designs::PublisherTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    ENV.delete("DESIGNS_PREVIEW_URL")
    FileUtils.remove_entry(@preview_root)
  end

  test "publishing master puts its files under the project's token, readable by Apache" do
    with_design_remote do |repo, _|
      seed_master(repo, { "index.html" => "<h1>Home</h1>", "designs/jobs.html" => "<p>Jobs</p>" })
      dir = Designs::Publisher.new(repo.project, repo).publish!("master", "master")
      token = repo.project.reload.design_preview_token
      assert_equal Pathname(@preview_root).join(token, "master"), dir
      assert_equal "<h1>Home</h1>", dir.join("index.html").read
      assert_equal "644", format("%o", dir.join("designs/jobs.html").stat.mode & 0o777)
      assert_equal "755", format("%o", dir.join("designs").stat.mode & 0o777)
    end
  end

  test "republishing replaces the slot and leaves nothing else behind" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/old.html" => "old" })
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      FileUtils.rm(repo.root.join("designs/old.html"))
      commit_files(repo, repo.root, { "designs/new.html" => "new" })
      dir = publisher.publish!("master", "master")
      assert_not dir.join("designs/old.html").exist?
      assert dir.join("designs/new.html").exist?
      assert_equal [ "master" ], Dir.children(dir.dirname)
    end
  end

  test "a work-in-progress slot lives under wip/" do
    with_design_remote do |repo, _|
      seed_master(repo)
      repo.worktree!("wip/REC-1")
      dir = Designs::Publisher.new(repo.project, repo).publish!("wip/REC-1", "wip/REC-1")
      assert_equal "wip/REC-1", dir.relative_path_from(Pathname(@preview_root).join(repo.project.design_preview_token)).to_s
    end
  end

  test "slots that could escape the token folder are refused" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      %w[../x wip/../../x master/../x .staging x/y].each do |slot|
        assert_raises(ArgumentError, slot) { publisher.publish!("master", slot) }
      end
    end
  end

  test "urls carry the token, the slot, the page and the contexts" do
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    publisher = Designs::Publisher.new(project, nil)
    assert_equal "https://preview.example/t0k/REC-1/designs/jobs.html?ctx=admin,workshop",
                 publisher.url("REC-1", "designs/jobs.html", ctx: %w[admin workshop])
    assert_equal "https://preview.example/t0k/master/index.html", publisher.url("master")
  end

  test "rotate_token! moves the previews and kills the old path" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      old = repo.project.reload.design_preview_token
      new = publisher.rotate_token!
      assert_not_equal old, new
      assert_not File.exist?(File.join(@preview_root, old))
      assert File.exist?(File.join(@preview_root, new, "master", "README.md"))
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/designs/publisher_test.rb`
Expected: FAIL with `uninitialized constant Designs::Publisher`.

- [ ] **Step 3: Write `Designs::Publisher`** to the interface above.

- Staging lives under the token folder, so the final rename stays on one filesystem and is atomic.
- `url` joins the `ctx` values with `,` after `CGI.escape` on each one.
- Run `publish!` inside `repo.synchronize`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/designs/publisher_test.rb`
Expected: PASS (6 runs).

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/publisher.rb test/services/designs/publisher_test.rb
git commit -m "feat: publish a design branch to the preview host, atomically, under a revocable token"
```

---

### Task 9: The design repo template and its browser runtime

**Files:**
- Create:
  - `lib/designs_template/README.md.erb`
  - `lib/designs_template/index.html`
  - `lib/designs_template/design_system/index.html`
  - `lib/designs_template/design_system/theme.css.tailwind4`
  - `lib/designs_template/design_system/theme.css.plain`
  - `lib/designs_template/components/index.html`
  - `lib/designs_template/designs/index.html`
  - `lib/designs_template/designs/contexts.json`
  - `lib/designs_template/runtime/flosis.js`
  - `lib/designs_template/runtime/nav.html`
  - `lib/designs_template/runtime/config.json.erb`
  - `lib/designs_template/runtime/kits/tailwind4.js`
  - `app/services/designs/template.rb`
- Modify: `config/application.rb` (`config.autoload_lib(ignore: %w[assets tasks mcp designs_template])`)
- Test: `test/services/designs/template_test.rb`

**Interfaces:**
- Consumes: `Project#design_base_kit`, `Project#name` (Task 1); `Designs::LeakGuard` (Task 7) in the test.
- Produces:
  - `Designs::Template::SOURCE = Rails.root.join("lib/designs_template")`
  - `Designs::Template.render_into(dir, project:)` copies the tree:
    - `*.erb` files are rendered with `project` and `kit` and lose the `.erb` extension;
    - `design_system/theme.css.<kit>` becomes `design_system/theme.css`, and the other kits' themes are dropped;
    - `runtime/kits/<kit>.js` becomes `runtime/kit.js` when it exists;
    - `runtime/kits/` itself is never copied.

**Template content:**

- **`README.md.erb`** — for developers and their AI, with no library content. It must contain:
  - `<%= project.name %> — designs`;
  - **Branches**, word for word:
    - `master` — all approved designs: the target look, possibly ahead of production;
    - `design/<KEY>` — the last approved design of a Jira task;
    - `wip/<KEY>` — work in progress, not approved, do not build from it;
    - tags `approved/<KEY>/<n>` mark each approval;
  - **What a task changed:** `git diff approved/<KEY>/<n>^1 approved/<KEY>/<n>`, and how to find the latest n: `git tag -l 'approved/<KEY>/*' --sort=-v:refname | head -1`;
  - **Run it locally:** `python3 -m http.server 8000` (or `npx serve .`), then open `http://localhost:8000`. `file://` is not supported.
    - Not the spec's `ruby -run -e httpd .`: Ruby 3.x ships no WEBrick, and it isn't in this bundle either.
  - **Structure:** the six entries;
  - **Components:** `<x-include src="components/<name>/<name>.html" title="…">children</x-include>`, with `{{name}}` placeholders and `<slot></slot>`;
  - **Contexts:** `designs/contexts.json`, `?ctx=<value>,<value>`, `data-ctx-show` / `data-ctx-hide`, `html[data-ctx-<dimension>]`;
  - **For AI assistants:** start from the Jira issue, check out `design/<KEY>`, read the changed screens, implement in the application's own stack, and take tokens from `design_system/theme.css`.
- **`runtime/config.json.erb`** — `{"kit": "<%= kit %>"}`.
- **`designs/contexts.json`** — `{"dimensions": []}`.
- **`theme.css.tailwind4`** — an `@theme { … }` block with 6–8 neutral placeholder tokens (`--color-primary`, `--color-on-primary`, `--color-surface`, `--color-on-surface`, `--font-sans`, `--radius-md`, …) and a comment that the setup run replaces them.
- **`theme.css.plain`** — the same tokens as `:root { --… }` custom properties.
- **`runtime/kits/tailwind4.js`** — vendored, unmodified:
  `curl -fsSL https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.1/dist/index.global.js -o lib/designs_template/runtime/kits/tailwind4.js`
  Record the provenance (package, version, URL, and why that version: Gold's `tailwindcss-ruby` 4.2.1) in a comment on `Designs::Template`, not in the vendored file.
- **`runtime/nav.html`** — a small nav linking `index.html`, `design_system/index.html`, `components/index.html` and `designs/index.html`, marking `{{current}}`.
- **The four `index.html` pages:**
  - Each loads `runtime/flosis.js` by a relative path (`runtime/flosis.js` at the root, `../runtime/flosis.js` one level down).
  - Each includes the nav with `<x-include src="runtime/nav.html" current="…"></x-include>`.
  - Each says, in one line, what will appear there ("The setup run fills this in").
  - The design-system page shows one swatch styled `bg-primary text-on-primary` (tailwind4) or `style="background: var(--color-primary)"` (plain).
- **`runtime/flosis.js`** — no build, no dependencies. Done in this order, then it dispatches `flosis:ready` on `document` and resolves `window.Flosis.ready` (a Promise):
  1. **Repo root:** `new URL("..", document.currentScript.src)`. Include `src`s and the files below resolve against it.
  2. **Config:** fetch `runtime/config.json`.
  3. **Theme:** fetch `design_system/theme.css`.
     - For `tailwind4`, insert it into `<head>` as `<style type="text/tailwindcss">`.
     - For `plain`, insert it as `<link rel="stylesheet">`.
  4. **Includes:** until no `x-include[src]` is left (stop after 10 rounds, which guards against cycles):
     - fetch each `src`, caching per URL;
     - replace every `{{name}}` with the element's `name` attribute, HTML-escaped (missing → empty);
     - move the element's children into the fragment's first `<slot></slot>`, if there is one;
     - replace the element with the fragment's nodes.
     - A failed fetch becomes `<div data-flosis-error style="border:2px solid #c00;padding:8px">Missing component: <src></div>`. Never fail silently.
  5. **Contexts:** fetch `designs/contexts.json` (`{"dimensions":[{"id","name","values":[{"id","name"}],"default"}]}`).
     - Per dimension, the active value is the first `?ctx=` value that belongs to it, else `default`, else its first value.
     - Set `data-ctx-<dimension id>="<value id>"` on `<html>`.
     - Hide (`hidden` attribute) every `[data-ctx-show]` whose space-separated list holds no active value, and every `[data-ctx-hide]` whose list holds one.
     - Expose `window.Flosis.ctx` as `{ dimensionId: valueId }`.
  6. **Links:** on click of a same-origin `a[href]` that doesn't start with `#`, rewrite its `ctx` query parameter to the active values joined by `,`, so the context survives navigation.
  7. **Kit:** for `tailwind4`, append `<script src="<root>runtime/kit.js">` last, so Tailwind's first scan sees the resolved page.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/designs/template_test.rb
require "test_helper"

class Designs::TemplateTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("template")
    @project = projects(:jira_project)
  end
  teardown { FileUtils.remove_entry(@dir) }

  test "renders exactly the six places the leak guard allows, and passes it" do
    Designs::Template.render_into(@dir, project: @project)
    assert_equal %w[README.md components design_system designs index.html runtime], Dir.children(@dir).sort
    changes = Dir.glob("**/*", base: @dir).select { |p| File.file?(File.join(@dir, p)) }
                 .map { |p| Designs::Repo::Change.new(path: p, added_text: File.read(File.join(@dir, p))) }
    assert_empty Designs::LeakGuard.new.check(changes)
  end

  test "the README names the project and the conventions a developer needs" do
    Designs::Template.render_into(@dir, project: @project)
    readme = File.read(File.join(@dir, "README.md"))
    [ @project.name, "design/<KEY>", "wip/<KEY>", "approved/<KEY>/<n>", "python3 -m http.server 8000", "?ctx=" ].each do |fact|
      assert_includes readme, fact
    end
  end

  test "the Tailwind kit ships the vendored browser build and a Tailwind theme" do
    @project.design_base_kit = "tailwind4"
    Designs::Template.render_into(@dir, project: @project)
    assert_equal({ "kit" => "tailwind4" }, JSON.parse(File.read(File.join(@dir, "runtime/config.json"))))
    assert_includes File.read(File.join(@dir, "runtime/kit.js")), "tailwindcss"
    assert_includes File.read(File.join(@dir, "design_system/theme.css")), "@theme"
    assert_not File.exist?(File.join(@dir, "runtime/kits"))
  end

  test "the plain kit ships no Tailwind at all" do
    @project.design_base_kit = "plain"
    Designs::Template.render_into(@dir, project: @project)
    assert_not File.exist?(File.join(@dir, "runtime/kit.js"))
    assert_not_includes File.read(File.join(@dir, "design_system/theme.css")), "@theme"
  end

  test "every page loads the runtime and includes the shared nav" do
    Designs::Template.render_into(@dir, project: @project)
    %w[index.html design_system/index.html components/index.html designs/index.html].each do |page|
      html = File.read(File.join(@dir, page))
      assert_match %r{<script src="(\.\./)?runtime/flosis\.js"}, html, page
      assert_includes html, %(<x-include src="runtime/nav.html"), page
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/designs/template_test.rb`
Expected: FAIL with `uninitialized constant Designs::Template`.

- [ ] **Step 3: Vendor the Tailwind build, write the template files, `runtime/flosis.js` and `Designs::Template`**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/services/designs/template_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 5: Verify the runtime in a browser**

1. Render the template:
   `bin/rails runner 'Designs::Template.render_into("tmp/template-check", project: Project.first)'`
2. In `tmp/template-check` only (never committed):
   - replace `designs/contexts.json` with one dimension, `{"id":"role","name":"Role","values":[{"id":"admin","name":"Admin"},{"id":"viewer","name":"Viewer"}],"default":"admin"}`;
   - add `designs/check.html`, which loads `../runtime/flosis.js` and holds `<p data-ctx-show="admin">admin only</p><p data-ctx-hide="admin">not admin</p><a href="../index.html">home</a>`.
3. Serve it: `python3 -m http.server 8123 --directory tmp/template-check`.
4. Open `http://localhost:8123/designs/check.html?ctx=viewer` with the Playwright MCP tools.

Expected:
- "admin only" is hidden and "not admin" is visible;
- `<html data-ctx-role="viewer">`;
- after clicking "home", the URL ends in `index.html?ctx=viewer`;
- `index.html` has no `x-include` element left and shows the nav;
- the swatch on `design_system/index.html` has a computed `background-color` equal to the theme's `--color-primary`;
- the browser console shows no errors.

Remove `tmp/template-check` afterwards.

- [ ] **Step 6: Commit**

```bash
git add lib/designs_template app/services/designs/template.rb config/application.rb test/services/designs/template_test.rb
git commit -m "feat: the design repo template — no build step, x-include components, contexts in the URL"
```

---

### Task 10: Initializing a project's design repo

**Files:**
- Create: `app/jobs/designs/initialize_repo_job.rb`
- Test: `test/jobs/designs/initialize_repo_job_test.rb`

**Interfaces:**
- Consumes:
  - `Designs::Repo`, `Designs::Repo.remote_url_override` (Task 6)
  - `Designs::Template.render_into` (Task 9)
  - `Designs::LeakGuard`, `Designs::Committer` (Task 7)
  - `Designs::Publisher#publish!` (Task 8)
  - `ProjectCredentials#design_repo_configured?`, `#design_repo_token`, `#github_token`, `#anthropic_api_key`
- Produces: `Designs::InitializeRepoJob.perform_later(project_id)`.
  - It does nothing unless `designs_enabled?` and `design_repo_configured?`.
  - It sets `design_repo_status` to `"initializing"`, then `"ready"` or `"error"` with `design_repo_error` (git's message, already scrubbed).
  - An already-initialized repo is only re-published.

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/designs/initialize_repo_job_test.rb
require "test_helper"

class Designs::InitializeRepoJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  test "an empty repo gets master from the template, pushed and published" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      project = repo.project.reload
      assert_equal "ready", project.design_repo_status
      assert remote_branch_sha(remote, "master")
      assert File.exist?(File.join(@preview_root, project.design_preview_token, "master", "runtime", "flosis.js"))
    end
  end

  test "an initialized repo gets no second commit" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      first = remote_branch_sha(remote, "master")
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert_equal first, remote_branch_sha(remote, "master")
      assert_equal "ready", repo.project.reload.design_repo_status
    end
  end

  test "records a push failure without the token" do
    with_design_remote do |repo, remote|
      FileUtils.chmod_R("a-w", remote)
      begin
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      ensure
        FileUtils.chmod_R("u+w", remote)
      end
      project = repo.project.reload
      assert_equal "error", project.design_repo_status
      assert project.design_repo_error.present?
      assert_not_includes project.design_repo_error, "design-token"
    end
  end

  test "does nothing for a project with Designs off" do
    with_design_remote do |repo, remote|
      repo.project.update!(designs_enabled: false)
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert_nil repo.project.reload.design_repo_status
      assert_nil remote_branch_sha(remote, "master")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/jobs/designs/initialize_repo_job_test.rb`
Expected: FAIL with `uninitialized constant Designs::InitializeRepoJob`.

- [ ] **Step 3: Write the job**

- `queue_as :default`.
- Everything runs inside `repo.synchronize`.
- The guard gets `secrets:` the project's design-repo, GitHub and Anthropic credentials (compacted).
- The commit message is `Start the design repo`.
- Rescue `StandardError` into the error status, keeping the first 500 characters of the message, as `ProjectRepoCheckoutJob` does.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/jobs/designs/initialize_repo_job_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/designs/initialize_repo_job.rb test/jobs/designs/initialize_repo_job_test.rb
git commit -m "feat: a project's empty design repo gets master from the template, pushed and published"
```

---

### Task 11: The Designs configuration tab

**Files:**
- Modify: `app/controllers/workshop/configuration_controller.rb`, `app/views/workshop/configuration/show.html.erb`, `config/routes.rb`
- Create: `app/views/workshop/configuration/_designs_tab.html.erb`
- Test: `test/controllers/workshop/configuration_designs_tab_test.rb`

**Interfaces:**
- Consumes: the Task 1 columns; `Designs::InitializeRepoJob` (Task 10); `Designs::Publisher#url`, `#rotate_token!` (Task 8); `Designs::Repo.new` (Task 6).
- Produces:
  - **Controller constants:**
    - tab `"designs"` in `TABS`, between `briefing` and `users`;
    - `TAB_PERMISSIONS["designs"] = :configuration`;
    - `DESIGN_FIELDS = %i[designs_enabled design_repo design_repo_token design_base_kit].freeze`;
    - `:design_repo_token` added to `SECRETS`.
  - **Route:** `post "configuration/rotate_design_preview_token", to: "configuration#rotate_design_preview_token", as: :rotate_design_preview_token_configuration`, which yields `workshop_rotate_design_preview_token_configuration_path`. It is gated by `require_permission!(:configuration)`.
  - **Saving the tab** (`save_designs(project)`):
    1. It saves `DESIGN_FIELDS` through `save_project_fields` with the toast `"Designs settings saved"`.
    2. When the project then has `designs_enabled?` and `design_repo_configured?`, and either the status isn't `"ready"` or `design_repo` just changed, it sets the status to `"initializing"`, clears the error, and enqueues `Designs::InitializeRepoJob`.

**The tab** follows the Briefing tab's `clar-card` layout. It is a plain `form_with` with a Save button, not auto-save. It has:
- a **"Designs on this project"** toggle (the GitHub modal's `clar-toggle` pattern);
- **DESIGN REPOSITORY** (placeholder `owner/name`; hint: "An empty GitHub repository. Flosis pushes only the design system, components, designs and the files needed to open them.");
- **ACCESS TOKEN** — write-only, with a masked placeholder like GitHub's; hint: "Needs write access to this repository only. Leave blank to keep the current token.";
- **BASE KIT** — a select of "Tailwind v4" (`tailwind4`) and "Plain CSS" (`plain`);
- a **status card**:
  - "Not set up" / "Setting up…" / "Ready" / "Failed: <design_repo_error>";
  - when ready, an "Open master preview ↗" link to `Designs::Publisher.new(project, nil).url("master")` with `target="_blank" rel="noopener noreferrer"`;
- a **"Preview links" card**, outside the main form: "Rotating makes every preview link sent so far, including those in Jira, stop working." and a `button_to "Rotate preview links"`.

The `show.html.erb` tab map gains `"designs" => "Designs"` in the same position.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/configuration_designs_tab_test.rb
require "test_helper"

class Workshop::ConfigurationDesignsTabTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "the Designs tab shows the on/off switch, repository, token and kit" do
    get workshop_configuration_path(tab: "designs")
    assert_response :success
    assert_select ".clar-tab-active", /Designs/
    assert_select "input[name='project[designs_enabled]']"
    assert_select "input[name='project[design_repo]']"
    assert_select "input[type=password][name='project[design_repo_token]']"
    assert_select "select[name='project[design_base_kit]'] option[value=tailwind4]"
    assert_select "select[name='project[design_base_kit]'] option[value=plain]"
  end

  test "switching Designs on with a repo and a token saves them and starts setting the repo up" do
    assert_enqueued_with(job: Designs::InitializeRepoJob, args: [ @project.id ]) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "1", design_repo: "acme/designs", design_repo_token: "dt", design_base_kit: "tailwind4" } }
    end
    @project.reload
    assert @project.designs_enabled?
    assert_equal "acme/designs", @project.design_repo
    assert_equal "dt", @project.design_repo_token
    assert_equal "initializing", @project.design_repo_status
    assert_redirected_to workshop_configuration_path(tab: "designs")
  end

  test "a blank token keeps the stored one" do
    @project.update!(design_repo_token: "keep-me")
    patch workshop_configuration_path, params: { tab: "designs", project: { design_repo: "acme/designs", design_repo_token: "" } }
    assert_equal "keep-me", @project.reload.design_repo_token
  end

  test "Designs left off queues nothing" do
    assert_no_enqueued_jobs(only: Designs::InitializeRepoJob) do
      patch workshop_configuration_path, params: { tab: "designs", project: {
        designs_enabled: "0", design_repo: "acme/designs", design_repo_token: "dt" } }
    end
  end

  test "a ready repo links to the master preview" do
    @project.update!(designs_enabled: true, design_repo: "acme/designs", design_repo_token: "dt",
                     design_repo_status: "ready", design_preview_token: "t0k")
    get workshop_configuration_path(tab: "designs")
    assert_select "a[href=?][target=_blank]", "#{Designs::Publisher.base_url}/t0k/master/index.html"
  end

  test "a failed setup shows git's message" do
    @project.update!(design_repo_status: "error", design_repo_error: "git push failed: permission denied")
    get workshop_configuration_path(tab: "designs")
    assert_select "body", /permission denied/
  end

  test "rotating the preview links changes the token" do
    @project.update!(design_preview_token: "old-token-old-token-old-token-12")
    post workshop_rotate_design_preview_token_configuration_path
    assert_redirected_to workshop_configuration_path(tab: "designs")
    assert_not_equal "old-token-old-token-old-token-12", @project.reload.design_preview_token
  end

  test "a Product Owner sees the Designs tab locked and can neither save nor rotate" do
    @project.update!(design_preview_token: "old-token-old-token-old-token-12")
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }

    get workshop_configuration_path
    assert_select "span.clar-tab[aria-disabled='true']", text: /Designs/

    patch workshop_configuration_path, params: { tab: "designs", project: { designs_enabled: "1" } }
    assert_response :forbidden
    post workshop_rotate_design_preview_token_configuration_path
    @project.reload
    assert_not @project.designs_enabled?
    assert_equal "old-token-old-token-old-token-12", @project.design_preview_token
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/configuration_designs_tab_test.rb`
Expected: FAIL. There is no Designs tab yet, the route is missing, and the tab renders the default.

- [ ] **Step 3: Add the tab to the controller, the route, the tab map and `_designs_tab.html.erb`**

- [ ] **Step 4: Run the new test and the existing configuration test**

Run: `bin/rails test test/controllers/workshop/configuration_designs_tab_test.rb && bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS. The existing tab tests are unaffected.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/workshop/configuration_controller.rb app/views/workshop/configuration/show.html.erb app/views/workshop/configuration/_designs_tab.html.erb config/routes.rb test/controllers/workshop/configuration_designs_tab_test.rb
git commit -m "feat: Configuration › Designs — switch Designs on, point it at a repo, rotate preview links"
```

---

### Task 12: The preview host — development server, Apache config, server checks

**Files:**
- Create: `bin/designs-preview` (executable)
- Modify: `lib/capistrano/tasks/setup.rake`, `config/deploy.rb`

**Interfaces:**
- Consumes: `Designs::Publisher.root` (Task 8).
- Produces:
  - `bin/designs-preview` serves `ENV["DESIGNS_PREVIEW_ROOT"] || "tmp/designs_preview"` on port `ENV["DESIGNS_PREVIEW_PORT"] || 3100` with `python3 -m http.server`. That matches `Designs::Publisher.base_url`'s development default.
  - `set :designs_preview_document_root, ENV["DESIGNS_PREVIEW_DOCUMENT_ROOT"]` in `config/deploy.rb`.
  - `cap production setup:designs_preview_htaccess`.

- [ ] **Step 1: Write `bin/designs-preview`** (a Ruby script that `exec`s `python3 -m http.server <port> --directory <root>` after `mkdir_p`), then `chmod 755`.

- [ ] **Step 2: Verify it locally**

1. Run `bin/designs-preview` in one terminal.
2. Publish a test slot from a console:

   ```ruby
   p = Project.first
   p.update!(designs_enabled: true, design_repo: "acme/x", design_repo_token: "t")
   remote = Dir.mktmpdir
   system("git", "init", "--bare", "-q", remote)
   system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/master")
   Designs::Repo.remote_url_override = remote
   Designs::InitializeRepoJob.perform_now(p.id)
   ```

3. `curl -s http://localhost:3100/<token>/master/index.html | head -5`

Expected: the template's `index.html`. Undo the console changes to `Project.first` afterwards.

- [ ] **Step 3: Add the Capistrano task**

`setup:designs_preview_htaccess` aborts with a clear message when `designs_preview_document_root` is unset. Otherwise it uploads this file, then runs `chmod 644` and moves Hostido's placeholder `index.html` aside, exactly as `setup:app_htaccess` does:

```apache
Options -Indexes -ExecCGI
DirectoryIndex index.html

RewriteEngine On
RewriteCond %{HTTPS} off
RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

# Half-published and replaced copies are never served.
RewriteRule (^|/)\.(staging|old)- - [F,L]

<IfModule mod_headers.c>
  # The project token is in every path: never hand it to another site.
  Header always set Referrer-Policy "no-referrer"
  Header always set X-Robots-Tag "noindex, nofollow"
  Header always set X-Content-Type-Options "nosniff"
  # Only Flosis may frame a preview (the Designs screen); Jira opens links top-level.
  Header always set Content-Security-Policy "frame-ancestors https://app.flosis.com"
</IfModule>
```

- [ ] **Step 4: Commit**

```bash
git add bin/designs-preview lib/capistrano/tasks/setup.rake config/deploy.rb
git commit -m "chore: a local preview server and the preview host's Apache config"
```

- [ ] **Step 5: Production checklist — stop and ask Kacper before each outward step**

1. **Kacper:** choose and register the preview domain, a separate registrable domain and not a `flosis.com` subdomain. Add it in the Hostido panel with TLS.
2. **Environment:** add `DESIGNS_PREVIEW_ROOT=/home/host420646/domains/<domain>/public_html` and `DESIGNS_PREVIEW_URL=https://<domain>` to `.env.production`, then run `cap production setup:upload_env`.
3. **Apache:** `DESIGNS_PREVIEW_DOCUMENT_ROOT=/home/host420646/domains/<domain>/public_html cap production setup:designs_preview_htaccess`
4. **On the server** (`ssh` as in the server runner reference):
   - `git --version` must be ≥ 2.20;
   - `claude --help | grep -- --bare` must print the flag.
   - If the CLI lacks it, updating the CLI changes every AI job's default model. Ask Kacper before updating.
5. **Deploy:** `git push`, then `cap production deploy`, right after a 5-minute automation tick with nothing claimed, because a deploy kills a running job.
6. **End to end, on a test project:**
   - with an empty GitHub repo and a fine-grained token (contents: write on that repo only), switch Designs on;
   - the status reaches **Ready**;
   - "Open master preview" opens the template;
   - `ssh hostido curl -sI https://<domain>/<token>/master/index.html` shows `Referrer-Policy: no-referrer`.
   Test from the server, because repeated curls from a laptop trip Hostido's bot challenge.
