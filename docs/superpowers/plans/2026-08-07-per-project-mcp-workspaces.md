# Per-Project MCP Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give AI Alerts & Automations working, project-scoped GitHub + Jira MCP tools by isolating each Project into its own server folder with per-project credentials and a generated `.mcp.json`, so onboarding a client with their own Jira/repo just works.

**Architecture:** Add encrypted per-Project credential columns with a `Project → Workspace → ENV` fallback resolver (`ProjectCredentials`). A `ProjectMcpConfig` service writes a `.mcp.json` (servers keyed exactly `github`/`jira`) into a per-project folder; `ProjectRepoCheckoutJob` clones the repo there. `ClaudeCliService` learns `--mcp-config --strict-mcp-config`, and `AlertRuleRunJob` regenerates the config and runs Claude inside the project's repo checkout. The legacy `PrReviewJob` and the shared `~/work/elvium` checkout are left untouched; the `elvium` project is grandfathered onto `~/work/elvium`.

**Tech Stack:** Rails 8.1, Ruby 3.4, Minitest, Solid Queue, MySQL (prod) / Postgres (dev), Capistrano. Claude CLI v2.1.220. GitHub MCP via `npx @modelcontextprotocol/server-github`; Jira MCP via `mcp-atlassian` (Python, pip).

## Global Constraints

- **Do NOT modify** `PrReviewJob`, `GithubClient.for(workspace)` (existing method), or the `~/work/elvium` checkout behavior. New code lives alongside.
- **`.mcp.json` server keys MUST be exactly `github` and `jira`** — these produce the tool names `mcp__github__*` / `mcp__jira__*` that match the existing `ClaudeCliService::AUTOMATION_TOOLS` allowlist. Any other key breaks tool matching.
- **Credential resolution order:** `Project → Workspace → ENV`. GitHub falls back Project→Workspace. Jira falls back Project→ENV (Workspace has no Jira cred columns).
- **Secrets encrypted:** `github_token` and `jira_api_token` on `projects` use Rails `encrypts`. Non-secret columns (repo, site, email, dir, status) are plain.
- **Encryption keys are a hard prerequisite:** `ActiveRecord::Encryption` keys must exist before any `encrypts` column is read/written. Task 1 sets this up.
- **Folder perms:** project folder `chmod 700`, `.mcp.json` `chmod 600`, app-user owned, `.gitignore`d.
- **elvium grandfathering:** the `elvium` project has `workspace_dir` set explicitly to `File.expand_path("~/work/elvium")` and is never re-cloned. Its automation `codebase_path` stays `~/work/elvium`.
- **Automation `codebase_path` = the repo checkout subfolder** (`<workspace_dir>/<repo-name>`), not the parent. `--mcp-config` uses the parent's `.mcp.json` absolute path.
- **No `--dangerously-skip-permissions`.** MCP tools are pre-approved via the existing `--allowedTools` list.
- **Local test caveat:** the dev Mac's `pg` gem segfaults running the suite. Write tests normally; verification runs on the production server (MySQL) via `bin/rails test` over SSH, or targeted `ruby -Itest` runs where a single file can load without the full pg path. Each task's "run tests" step notes this.
- **Blank-token-preserves:** when a credential form submits a blank token, keep the existing encrypted value (mirror the existing `github_token` blank-delete pattern).

---

## File Structure

- `config/credentials.yml.enc` / `config/master.key` — AR encryption keys (Task 1).
- `db/migrate/*_add_project_credential_columns.rb` — new columns (Task 2).
- `app/models/project.rb` — `encrypts` declarations + `legacy_elvium?` + dir helpers (Task 2, 5).
- `app/services/project_credentials.rb` — the resolver (Task 3).
- `app/services/github_client.rb` — add `for_project` (Task 4).
- `app/services/project_mcp_config.rb` — folder + `.mcp.json` writer (Task 5).
- `app/jobs/project_repo_checkout_job.rb` — clone/pull (Task 6).
- `app/services/claude_cli_service.rb` — `mcp_config:` param (Task 7).
- `app/jobs/alert_rule_run_job.rb` — wire per-project run (Task 8).
- `app/controllers/workshop/configuration_controller.rb` + `_manage_jira.html.erb` + `_manage_github.html.erb` — editable creds + triggers (Task 9).
- `.gitignore` — ignore client workspace dirs if any land in-repo (Task 5).
- `config/deploy.rb` / docs — deploy prerequisites (Task 10).

---

## Task 1: Configure ActiveRecord encryption keys

**Files:**
- Modify: `config/credentials.yml.enc` (via `rails credentials:edit`)
- Test: `test/models/encryption_config_test.rb` (Create)

**Interfaces:**
- Produces: working `ActiveRecord::Encryption` so later `encrypts` columns function.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/encryption_config_test.rb
require "test_helper"

class EncryptionConfigTest < ActiveSupport::TestCase
  test "ActiveRecord encryption is configured with keys" do
    config = ActiveRecord::Encryption.config
    assert config.primary_key.present?, "primary_key must be set"
    assert config.deterministic_key.present?, "deterministic_key must be set"
    assert config.key_derivation_salt.present?, "key_derivation_salt must be set"
  end

  test "a string can be encrypted and decrypted round-trip" do
    encryptor = ActiveRecord::Encryption::Encryptor.new
    cipher = encryptor.encrypt("secret-token", key_provider: ActiveRecord::Encryption.key_provider)
    assert_not_equal "secret-token", cipher
    assert_equal "secret-token", encryptor.decrypt(cipher, key_provider: ActiveRecord::Encryption.key_provider)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (on server): `bin/rails test test/models/encryption_config_test.rb`
Expected: FAIL — keys not configured (`primary_key must be set`).

- [ ] **Step 3: Generate and store keys**

Run locally to generate a key set:
```bash
bin/rails db:encryption:init
```
Copy the printed `active_record_encryption:` block into credentials:
```bash
EDITOR="nano" bin/rails credentials:edit
```
Paste:
```yaml
active_record_encryption:
  primary_key: <generated>
  deterministic_key: <generated>
  key_derivation_salt: <generated>
```
If the deploy uses ENV instead of `master.key` on the server, also set
`RAILS_MASTER_KEY` (or the three `ACTIVE_RECORD_ENCRYPTION_*` ENV vars) in the
server's `shared/.env`. Confirm `config/master.key` is present locally and NOT
committed (already in `.gitignore`).

- [ ] **Step 4: Run test to verify it passes**

Run (on server, after deploying master key / env): `bin/rails test test/models/encryption_config_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add config/credentials.yml.enc test/models/encryption_config_test.rb
git commit -m "feat: configure ActiveRecord encryption keys for per-project secrets"
```

Note: `config/master.key` is git-ignored; the deploy must have it on the server (via `shared/` symlink or `RAILS_MASTER_KEY` env). Flag this in Task 10.

---

## Task 2: Add per-project credential columns + encrypts

**Files:**
- Create: `db/migrate/<ts>_add_project_credential_columns.rb`
- Modify: `app/models/project.rb`
- Modify: `db/schema.rb` (via migrate)
- Test: `test/models/project_credentials_columns_test.rb` (Create)

**Interfaces:**
- Produces: `Project` columns `github_repo, github_token(enc), jira_site, jira_email, jira_api_token(enc), workspace_dir, repo_checkout_status, repo_checkout_error, mcp_synced_at`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/project_credentials_columns_test.rb
require "test_helper"

class ProjectCredentialsColumnsTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "new credential columns exist" do
    %w[github_repo github_token jira_site jira_email jira_api_token
       workspace_dir repo_checkout_status repo_checkout_error mcp_synced_at].each do |col|
      assert_includes Project.column_names, col, "missing column #{col}"
    end
  end

  test "github_token and jira_api_token are encrypted at rest" do
    @project.update!(github_token: "ghp_secret", jira_api_token: "jira_secret")
    raw = Project.connection.select_one(
      "SELECT github_token, jira_api_token FROM projects WHERE id = #{@project.id}"
    )
    assert_not_equal "ghp_secret", raw["github_token"], "github_token must be encrypted at rest"
    assert_not_equal "jira_secret", raw["jira_api_token"], "jira_api_token must be encrypted at rest"
    assert_equal "ghp_secret", @project.reload.github_token
    assert_equal "jira_secret", @project.reload.jira_api_token
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (on server): `bin/rails test test/models/project_credentials_columns_test.rb`
Expected: FAIL — columns missing.

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/<ts>_add_project_credential_columns.rb
class AddProjectCredentialColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :github_repo, :string unless column_exists?(:projects, :github_repo)
    add_column :projects, :github_token, :text unless column_exists?(:projects, :github_token)
    add_column :projects, :jira_site, :string unless column_exists?(:projects, :jira_site)
    add_column :projects, :jira_email, :string unless column_exists?(:projects, :jira_email)
    add_column :projects, :jira_api_token, :text unless column_exists?(:projects, :jira_api_token)
    add_column :projects, :workspace_dir, :string unless column_exists?(:projects, :workspace_dir)
    add_column :projects, :repo_checkout_status, :string unless column_exists?(:projects, :repo_checkout_status)
    add_column :projects, :repo_checkout_error, :string unless column_exists?(:projects, :repo_checkout_error)
    add_column :projects, :mcp_synced_at, :datetime unless column_exists?(:projects, :mcp_synced_at)
  end
end
```
Note: encrypted columns use `:text` (ciphertext is longer than plaintext and MySQL `string`/varchar could truncate). Non-secret columns are `:string`.

- [ ] **Step 4: Declare encrypts on the model**

In `app/models/project.rb`, after the `belongs_to`/`has_many` block:
```ruby
  encrypts :github_token
  encrypts :jira_api_token
```

- [ ] **Step 5: Run migration + tests**

Run (on server): `bin/rails db:migrate && bin/rails test test/models/project_credentials_columns_test.rb`
Expected: PASS. Verify `AlertRule.column_names`-style check that `Project.column_names` includes all 9.

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/project.rb db/schema.rb test/models/project_credentials_columns_test.rb
git commit -m "feat: add encrypted per-project credential columns"
```

---

## Task 3: ProjectCredentials resolver

**Files:**
- Create: `app/services/project_credentials.rb`
- Test: `test/services/project_credentials_test.rb` (Create)

**Interfaces:**
- Consumes: `Project` cred columns (Task 2), `workspace.github_repo/github_token`, ENV `JIRA_DOMAIN/JIRA_EMAIL/JIRA_API_TOKEN`.
- Produces:
  - `ProjectCredentials.new(project)` with readers `github_repo`, `github_token`, `jira_site`, `jira_email`, `jira_api_token`, `jira_key`.
  - predicates `github_configured?`, `jira_configured?`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/project_credentials_test.rb
require "test_helper"

class ProjectCredentialsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_repo: "ws/repo", github_token: "ws_token")
    @project = projects(:jira_project)
    @project.update!(external_reference: "DEV")
  end

  test "github falls back to workspace when project is blank" do
    creds = ProjectCredentials.new(@project)
    assert_equal "ws/repo", creds.github_repo
    assert_equal "ws_token", creds.github_token
  end

  test "project github overrides workspace" do
    @project.update!(github_repo: "proj/repo", github_token: "proj_token")
    creds = ProjectCredentials.new(@project)
    assert_equal "proj/repo", creds.github_repo
    assert_equal "proj_token", creds.github_token
  end

  test "jira falls back to ENV when project is blank" do
    ENV["JIRA_DOMAIN"] = "env.atlassian.net"
    ENV["JIRA_EMAIL"] = "env@example.com"
    ENV["JIRA_API_TOKEN"] = "env_token"
    creds = ProjectCredentials.new(@project)
    assert_equal "env.atlassian.net", creds.jira_site
    assert_equal "env@example.com", creds.jira_email
    assert_equal "env_token", creds.jira_api_token
  ensure
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
  end

  test "project jira overrides ENV" do
    ENV["JIRA_DOMAIN"] = "env.atlassian.net"
    @project.update!(jira_site: "proj.atlassian.net", jira_email: "p@x.com", jira_api_token: "pt")
    creds = ProjectCredentials.new(@project)
    assert_equal "proj.atlassian.net", creds.jira_site
    assert_equal "p@x.com", creds.jira_email
    assert_equal "pt", creds.jira_api_token
  ensure
    ENV.delete("JIRA_DOMAIN")
  end

  test "jira_key comes from external_reference" do
    assert_equal "DEV", ProjectCredentials.new(@project).jira_key
  end

  test "configured predicates" do
    @project.update!(github_repo: "p/r", github_token: "t",
                     jira_site: "s", jira_email: "e", jira_api_token: "jt")
    creds = ProjectCredentials.new(@project)
    assert creds.github_configured?
    assert creds.jira_configured?
  end

  test "not configured when creds missing everywhere" do
    @workspace.update!(github_repo: nil, github_token: nil)
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
    creds = ProjectCredentials.new(@project)
    assert_not creds.github_configured?
    assert_not creds.jira_configured?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/project_credentials_test.rb`
Expected: FAIL — `uninitialized constant ProjectCredentials`.

- [ ] **Step 3: Implement**

```ruby
# app/services/project_credentials.rb
# Single source of truth for "what credentials does this project use".
# Resolution order: Project column -> Workspace column -> ENV (Jira only).
# Consumed by ProjectMcpConfig, GithubClient.for_project, and automation
# JiraClient instantiation. Legacy HR / PrReviewJob do NOT use this.
class ProjectCredentials
  def initialize(project)
    @project = project
    @workspace = project.workspace
  end

  def github_repo
    @project.github_repo.presence || @workspace&.github_repo.presence
  end

  def github_token
    @project.github_token.presence || @workspace&.github_token.presence
  end

  def jira_site
    @project.jira_site.presence || ENV["JIRA_DOMAIN"].presence
  end

  def jira_email
    @project.jira_email.presence || ENV["JIRA_EMAIL"].presence
  end

  def jira_api_token
    @project.jira_api_token.presence || ENV["JIRA_API_TOKEN"].presence
  end

  def jira_key
    @project.external_reference.presence
  end

  def github_configured?
    github_repo.present? && github_token.present?
  end

  def jira_configured?
    jira_site.present? && jira_email.present? && jira_api_token.present?
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/project_credentials_test.rb`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/project_credentials.rb test/services/project_credentials_test.rb
git commit -m "feat: ProjectCredentials resolver with Project->Workspace->ENV fallback"
```

---

## Task 4: GithubClient.for_project

**Files:**
- Modify: `app/services/github_client.rb` (add class method only; do NOT touch existing `for`)
- Test: `test/services/github_client_for_project_test.rb` (Create)

**Interfaces:**
- Consumes: `ProjectCredentials` (Task 3).
- Produces: `GithubClient.for_project(project)` returning a `GithubClient` built from resolved creds.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/github_client_for_project_test.rb
require "test_helper"

class GithubClientForProjectTest < ActiveSupport::TestCase
  test "for_project builds a configured client from resolved creds" do
    workspace = workspaces(:one)
    workspace.update!(github_repo: "ws/repo", github_token: "ws_token")
    project = projects(:jira_project)
    client = GithubClient.for_project(project)
    assert client.configured?, "should be configured via workspace fallback"
  end

  test "for_project is not configured when nothing resolves" do
    workspace = workspaces(:one)
    workspace.update!(github_repo: nil, github_token: nil)
    project = projects(:jira_project)
    project.update!(github_repo: nil, github_token: nil)
    assert_not GithubClient.for_project(project).configured?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/github_client_for_project_test.rb`
Expected: FAIL — `undefined method for_project`.

- [ ] **Step 3: Implement (add after existing `self.for`)**

```ruby
  # Resolver-backed variant for per-project automations. Leaves the existing
  # workspace-based `for` untouched (used by legacy PrReviewJob).
  def self.for_project(project)
    creds = ProjectCredentials.new(project)
    new(token: creds.github_token, repo: creds.github_repo)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/github_client_for_project_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/github_client.rb test/services/github_client_for_project_test.rb
git commit -m "feat: GithubClient.for_project using ProjectCredentials"
```

---

## Task 5: ProjectMcpConfig (folder + .mcp.json writer) + Project dir helpers

**Files:**
- Create: `app/services/project_mcp_config.rb`
- Modify: `app/models/project.rb` (add `legacy_elvium?`, `ensure_workspace_dir!`, `repo_checkout_path`)
- Modify: `.gitignore` (defensive: ignore `/tmp/clients` test dirs if used)
- Test: `test/services/project_mcp_config_test.rb` (Create)

**Interfaces:**
- Consumes: `ProjectCredentials` (Task 3), `Project#workspace_dir`.
- Produces:
  - `ProjectMcpConfig.write!(project)` → writes `<workspace_dir>/.mcp.json`, sets perms + `mcp_synced_at`. Returns the path.
  - `ProjectMcpConfig.path_for(project)` → `"<workspace_dir>/.mcp.json"`.
  - `Project#legacy_elvium?` → true for the grandfathered elvium project.
  - `Project#repo_checkout_path` → `"<workspace_dir>/<repo-name>"` (or `~/work/elvium` for legacy).

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/project_mcp_config_test.rb
require "test_helper"
require "json"
require "fileutils"

class ProjectMcpConfigTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @project = projects(:jira_project)
    @project.update!(workspace_dir: @dir, github_repo: "acme/app", github_token: "ght",
                     jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt",
                     external_reference: "DEV")
  end
  teardown { FileUtils.remove_entry(@dir) if File.exist?(@dir) }

  test "writes .mcp.json with github and jira servers keyed exactly" do
    path = ProjectMcpConfig.write!(@project)
    assert_equal File.join(@dir, ".mcp.json"), path
    json = JSON.parse(File.read(path))
    servers = json["mcpServers"]
    assert servers.key?("github"), "server key must be exactly 'github'"
    assert servers.key?("jira"), "server key must be exactly 'jira'"
    assert_equal "npx", servers["github"]["command"]
    assert_equal "ght", servers["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]
    assert_equal "mcp-atlassian", servers["jira"]["command"]
    assert_equal "https://acme.atlassian.net", servers["jira"]["env"]["JIRA_URL"]
    assert_equal "jt", servers["jira"]["env"]["JIRA_API_TOKEN"]
  end

  test "file is chmod 600 and dir 700" do
    path = ProjectMcpConfig.write!(@project)
    assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    assert_equal "700", format("%o", File.stat(@dir).mode & 0o777)
  end

  test "omits a server whose creds do not resolve" do
    @project.update!(github_repo: nil, github_token: nil)
    @project.workspace.update!(github_repo: nil, github_token: nil)
    path = ProjectMcpConfig.write!(@project)
    json = JSON.parse(File.read(path))
    assert_not json["mcpServers"].key?("github"), "github omitted when unconfigured"
    assert json["mcpServers"].key?("jira")
  end

  test "sets mcp_synced_at" do
    assert_nil @project.mcp_synced_at
    ProjectMcpConfig.write!(@project)
    assert_not_nil @project.reload.mcp_synced_at
  end

  test "self-heals a deleted file" do
    path = ProjectMcpConfig.write!(@project)
    File.delete(path)
    ProjectMcpConfig.write!(@project)
    assert File.exist?(path)
  end

  test "path_for returns the mcp.json path" do
    assert_equal File.join(@dir, ".mcp.json"), ProjectMcpConfig.path_for(@project)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/project_mcp_config_test.rb`
Expected: FAIL — `uninitialized constant ProjectMcpConfig`.

- [ ] **Step 3: Implement the service**

```ruby
# app/services/project_mcp_config.rb
require "json"
require "fileutils"

# Writes a per-project .mcp.json wiring the `github` and `jira` stdio MCP
# servers to that project's resolved credentials. DB is the source of truth;
# call write! on integration save and again right before each automation run
# (self-heals a missing/stale file). Server keys MUST be exactly "github" /
# "jira" so tool names match ClaudeCliService::AUTOMATION_TOOLS.
class ProjectMcpConfig
  FILENAME = ".mcp.json".freeze

  def self.path_for(project)
    File.join(project.workspace_dir, FILENAME)
  end

  def self.write!(project)
    new(project).write!
  end

  def initialize(project)
    @project = project
    @creds = ProjectCredentials.new(project)
  end

  def write!
    dir = @project.workspace_dir
    raise ArgumentError, "project has no workspace_dir" if dir.blank?

    FileUtils.mkdir_p(dir)
    File.chmod(0o700, dir)

    path = File.join(dir, FILENAME)
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(config_hash))
    File.chmod(0o600, tmp)
    File.rename(tmp, path)

    @project.update_column(:mcp_synced_at, Time.current)
    path
  end

  private

  def config_hash
    servers = {}
    servers["github"] = github_server if @creds.github_configured?
    servers["jira"] = jira_server if @creds.jira_configured?
    { "mcpServers" => servers }
  end

  def github_server
    {
      "type" => "stdio",
      "command" => "npx",
      "args" => ["-y", "@modelcontextprotocol/server-github"],
      "env" => { "GITHUB_PERSONAL_ACCESS_TOKEN" => @creds.github_token }
    }
  end

  def jira_server
    {
      "type" => "stdio",
      "command" => "mcp-atlassian",
      "env" => {
        "JIRA_URL" => "https://#{@creds.jira_site}",
        "JIRA_USERNAME" => @creds.jira_email,
        "JIRA_API_TOKEN" => @creds.jira_api_token
      }
    }
  end
end
```

- [ ] **Step 4: Add Project helpers**

In `app/models/project.rb`:
```ruby
  ELVIUM_LEGACY_DIR = File.expand_path("~/work/elvium").freeze
  CLIENTS_BASE_DIR = ENV.fetch("CLIENTS_BASE_DIR", File.expand_path("~/work/clients")).freeze

  # The grandfathered project that keeps using the shared ~/work/elvium checkout.
  def legacy_elvium?
    workspace_dir.present? && File.expand_path(workspace_dir) == ELVIUM_LEGACY_DIR
  end

  # Absolute path to this project's isolated folder; assigns a default the first
  # time (unless already set, e.g. legacy elvium).
  def ensure_workspace_dir!
    return workspace_dir if workspace_dir.present?
    dir = File.join(CLIENTS_BASE_DIR, workspace_id.to_s, id.to_s)
    update_column(:workspace_dir, dir)
    dir
  end

  # Where Claude should chdir for automations: the repo checkout subfolder, or
  # the legacy elvium dir itself. Falls back to the shared ~/work/elvium when no
  # per-project dir is set (a project that never configured GitHub), so the
  # chdir is always a real directory.
  def repo_checkout_path
    return ELVIUM_LEGACY_DIR if legacy_elvium? || workspace_dir.blank?
    repo = ProjectCredentials.new(self).github_repo
    name = repo.to_s.split("/").last.presence || "repo"
    File.join(workspace_dir.to_s, name)
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/services/project_mcp_config_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add app/services/project_mcp_config.rb app/models/project.rb test/services/project_mcp_config_test.rb
git commit -m "feat: ProjectMcpConfig writes per-project .mcp.json; Project dir helpers"
```

---

## Task 6: ProjectRepoCheckoutJob

**Files:**
- Create: `app/jobs/project_repo_checkout_job.rb`
- Test: `test/jobs/project_repo_checkout_job_test.rb` (Create)

**Interfaces:**
- Consumes: `ProjectCredentials` (Task 3), `Project#ensure_workspace_dir!`, `Project#repo_checkout_path`, `Project#legacy_elvium?`.
- Produces: `ProjectRepoCheckoutJob.perform_now(project_id)` — clones or pulls; sets `repo_checkout_status`/`repo_checkout_error`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/project_repo_checkout_job_test.rb
require "test_helper"

class ProjectRepoCheckoutJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:jira_project)
    @project.workspace.update!(github_repo: "acme/app", github_token: "ght")
  end

  # Capture git commands instead of hitting the network.
  def with_git_capture
    calls = []
    ProjectRepoCheckoutJob.stub_git = ->(cmd, chdir:) { calls << { cmd: cmd, chdir: chdir }; true }
    yield calls
  ensure
    ProjectRepoCheckoutJob.stub_git = nil
  end

  test "clones when no checkout exists and marks ready" do
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert calls.any? { |c| c[:cmd].include?("clone") }, "should clone"
    end
    assert_equal "ready", @project.reload.repo_checkout_status
  end

  test "skips clone for legacy elvium" do
    @project.update_column(:workspace_dir, Project::ELVIUM_LEGACY_DIR)
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert_empty calls, "legacy elvium must not clone/pull"
    end
  end

  test "records error status when git fails" do
    ProjectRepoCheckoutJob.stub_git = ->(*, **) { raise "network exploded" }
    begin
      assert_nothing_raised { ProjectRepoCheckoutJob.perform_now(@project.id) }
    ensure
      ProjectRepoCheckoutJob.stub_git = nil
    end
    assert_equal "error", @project.reload.repo_checkout_status
    assert_match "network exploded", @project.repo_checkout_error.to_s
  end

  test "does nothing when github not configured" do
    @project.workspace.update!(github_repo: nil, github_token: nil)
    assert_nothing_raised { ProjectRepoCheckoutJob.perform_now(@project.id) }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/project_repo_checkout_job_test.rb`
Expected: FAIL — `uninitialized constant ProjectRepoCheckoutJob`.

- [ ] **Step 3: Implement**

```ruby
# app/jobs/project_repo_checkout_job.rb
# Clones (or fast-forward pulls) a project's repo into its isolated folder,
# using the resolved GitHub token. Enqueued when the GitHub integration is
# saved. Legacy elvium is skipped (it uses the shared ~/work/elvium checkout).
class ProjectRepoCheckoutJob < ApplicationJob
  queue_as :default

  # Test seam: a lambda ->(cmd, chdir:) that runs a git command. Nil in prod.
  class << self
    attr_accessor :stub_git
  end

  def perform(project_id)
    project = Project.find_by(id: project_id)
    return unless project
    return if project.legacy_elvium?

    creds = ProjectCredentials.new(project)
    return unless creds.github_configured?

    project.ensure_workspace_dir!
    checkout = project.repo_checkout_path

    project.update_columns(repo_checkout_status: "cloning", repo_checkout_error: nil)

    if Dir.exist?(File.join(checkout, ".git"))
      run_git(["git", "pull", "--ff-only"], chdir: checkout)
    else
      url = "https://#{creds.github_token}@github.com/#{creds.github_repo}.git"
      FileUtils.mkdir_p(File.dirname(checkout))
      run_git(["git", "clone", url, checkout], chdir: File.dirname(checkout))
    end

    project.update_columns(repo_checkout_status: "ready", repo_checkout_error: nil)
  rescue => e
    Rails.logger.error("[ProjectRepoCheckoutJob] #{e.message}")
    project&.update_columns(repo_checkout_status: "error", repo_checkout_error: e.message.to_s.first(500))
  end

  private

  def run_git(cmd, chdir:)
    return self.class.stub_git.call(cmd, chdir: chdir) if self.class.stub_git

    ok = system(*cmd, chdir: chdir, out: File::NULL, err: File::NULL)
    raise "git failed: #{cmd.reject { |a| a.include?('@github.com') }.join(' ')}" unless ok
    true
  end
end
```
Note: `require "fileutils"` is loaded transitively by Rails; if the isolated test run complains, add `require "fileutils"` at the top.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/jobs/project_repo_checkout_job_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/project_repo_checkout_job.rb test/jobs/project_repo_checkout_job_test.rb
git commit -m "feat: ProjectRepoCheckoutJob clones/pulls per-project repo"
```

---

## Task 7: ClaudeCliService --mcp-config support

**Files:**
- Modify: `app/services/claude_cli_service.rb` (`initialize`, `build_command`)
- Test: `test/services/claude_cli_service_mcp_test.rb` (Create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `ClaudeCliService.new(..., mcp_config: "/path/.mcp.json")` adds `--mcp-config <path> --strict-mcp-config` to the command. Absent `mcp_config:` → command unchanged.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/claude_cli_service_mcp_test.rb
require "test_helper"

class ClaudeCliServiceMcpTest < ActiveSupport::TestCase
  # build_command is private; test via send.
  test "includes --mcp-config and --strict-mcp-config when mcp_config given" do
    svc = ClaudeCliService.new(mcp_config: "/srv/proj/.mcp.json")
    cmd = svc.send(:build_command)
    assert_includes cmd, "--mcp-config"
    assert_includes cmd, "/srv/proj/.mcp.json"
    assert_includes cmd, "--strict-mcp-config"
  end

  test "omits mcp flags when mcp_config not given" do
    svc = ClaudeCliService.new
    cmd = svc.send(:build_command)
    assert_not_includes cmd, "--mcp-config"
    assert_not_includes cmd, "--strict-mcp-config"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/claude_cli_service_mcp_test.rb`
Expected: FAIL — `unknown keyword: :mcp_config`.

- [ ] **Step 3: Implement**

In `initialize` signature add `mcp_config: nil` and store `@mcp_config = mcp_config`:
```ruby
  def initialize(codebase_path: nil, allowed_tools: nil, model: nil, mcp_config: nil)
    @codebase_path = codebase_path || ENV.fetch("CHAT_CODEBASE_PATH", DEFAULT_CODEBASE_PATH)
    @allowed_tools = allowed_tools || ALLOWED_TOOLS
    @model = model
    @mcp_config = mcp_config
  end
```
In `build_command`, after the `--model` line and before the allowed-tools loop:
```ruby
    if @mcp_config.present?
      cmd += ["--mcp-config", @mcp_config, "--strict-mcp-config"]
    end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/claude_cli_service_mcp_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/claude_cli_service.rb test/services/claude_cli_service_mcp_test.rb
git commit -m "feat: ClaudeCliService supports --mcp-config/--strict-mcp-config"
```

---

## Task 8: Wire AlertRuleRunJob to per-project MCP

**Files:**
- Modify: `app/jobs/alert_rule_run_job.rb` (`run_ai`)
- Test: `test/jobs/alert_rule_run_job_test.rb` (add cases)

**Interfaces:**
- Consumes: `ProjectMcpConfig.write!/path_for` (Task 5), `Project#repo_checkout_path` (Task 5), `ClaudeCliService(mcp_config:)` (Task 7), `ProjectCredentials` (Task 3).
- Produces: automations run Claude inside the project repo checkout with the project's `.mcp.json`.

- [ ] **Step 1: Write the failing tests (append to existing file)**

```ruby
  test "run regenerates the project's mcp config and passes it to the CLI" do
    captured = {}
    orig_init = ClaudeCliService.instance_method(:initialize)
    ClaudeCliService.define_method(:initialize) do |**kw|
      captured[:codebase_path] = kw[:codebase_path]
      captured[:mcp_config] = kw[:mcp_config]
      orig_init.bind(self).call(**kw)
    end
    wrote = []
    orig_write = ProjectMcpConfig.method(:write!)
    ProjectMcpConfig.define_singleton_method(:write!) { |p| wrote << p.id; orig_write.call(p) }

    begin
      @rule.project.update_column(:workspace_dir, Project::ELVIUM_LEGACY_DIR)
      with_webhook_post { with_ai(block(alert: false, memory: "{}")) { AlertRuleRunJob.perform_now(@rule.id) } }
    ensure
      ClaudeCliService.define_method(:initialize, orig_init)
      ProjectMcpConfig.define_singleton_method(:write!, orig_write)
    end

    assert_includes wrote, @rule.project.id, "must regenerate mcp config before running"
    assert_equal Project::ELVIUM_LEGACY_DIR, captured[:codebase_path]
    assert_equal ProjectMcpConfig.path_for(@rule.project), captured[:mcp_config]
  end
```
(The existing setup's `@rule` already has a `project`; `projects(:jira_project)` fixture is its project. Ensure the fixture has a `workspace_dir` or the test sets it, as above.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/alert_rule_run_job_test.rb -n /regenerates/`
Expected: FAIL — `mcp_config` not passed / `write!` not called.

- [ ] **Step 3: Implement in `run_ai`**

Replace the service construction in `run_ai(rule)`:
```ruby
  def run_ai(rule)
    project = rule.project
    ProjectMcpConfig.write!(project) if project.workspace_dir.present?

    prompt = build_prompt(rule)
    service = ClaudeCliService.new(
      codebase_path: project.repo_checkout_path,
      allowed_tools: ClaudeCliService::AUTOMATION_TOOLS,
      mcp_config: (ProjectMcpConfig.path_for(project) if project.workspace_dir.present?)
    )
    service.start_session(prompt: prompt)[:response].to_s.tap do |response|
      return nil if cli_failed?(response)
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[AlertRuleRunJob] claude error: #{e.message}")
    nil
  end
```
Keep the module `CODEBASE_PATH` constant for backward-compat. When a project has a `workspace_dir`, the run uses its repo subfolder + `.mcp.json`; when it doesn't, `repo_checkout_path` returns the shared `~/work/elvium` (see Task 5's `repo_checkout_path`) and `mcp_config:` is nil — i.e. exactly the pre-feature behavior. elvium gets its legacy dir set in Task 10.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/jobs/alert_rule_run_job_test.rb`
Expected: PASS (existing suite + new case). The pre-existing "uses the automation tool set" test still passes (tools unchanged).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/alert_rule_run_job.rb test/jobs/alert_rule_run_job_test.rb
git commit -m "feat: AlertRuleRunJob runs Claude per-project with its .mcp.json"
```

---

## Task 9: Editable Jira/GitHub credentials in Configuration UI

**Files:**
- Modify: `app/controllers/workshop/configuration_controller.rb` (`update_integrations_settings`, `integrations_settings_params`, add Jira save + triggers)
- Modify: `app/views/workshop/configuration/_manage_jira.html.erb` (editable fields)
- Modify: `app/views/workshop/configuration/_manage_github.html.erb` (persist to project + trigger)
- Test: `test/controllers/workshop/configuration_integrations_test.rb` (Create)

**Interfaces:**
- Consumes: `ProjectMcpConfig.write!` (Task 5), `ProjectRepoCheckoutJob` (Task 6).
- Produces: saving GitHub/Jira writes project cred columns (blank-token-preserves), regenerates `.mcp.json`, and (GitHub) enqueues checkout.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/configuration_integrations_test.rb
require "test_helper"

class Workshop::ConfigurationIntegrationsTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    sign_in_as(users(:one)) # admin/owner with config access (matches other workshop controller tests)
  end

  test "saving jira creds persists encrypted token to the project" do
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt-secret" }
    }
    @project.reload
    assert_equal "acme.atlassian.net", @project.jira_site
    assert_equal "jt-secret", @project.jira_api_token
    raw = Project.connection.select_value("SELECT jira_api_token FROM projects WHERE id=#{@project.id}")
    assert_not_equal "jt-secret", raw
  end

  test "blank jira token preserves the existing value" do
    @project.update!(jira_api_token: "keep-me")
    patch workshop_configuration_path(tab: "integrations"), params: {
      integration: "jira",
      project: { jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "" }
    }
    assert_equal "keep-me", @project.reload.jira_api_token
  end

  test "saving github enqueues the checkout job" do
    assert_enqueued_with(job: ProjectRepoCheckoutJob) do
      patch workshop_configuration_path(tab: "integrations"), params: {
        integration: "github",
        project: { github_repo: "acme/app", github_token: "ght" }
      }
    end
  end
end
```
(Auth helper is `sign_in_as(users(:one))` — the admin/owner fixture used across `test/controllers/workshop/*_test.rb`. `@project = projects(:jira_project)` must belong to `users(:one)`'s workspace and be the `current_workshop_project`; if the test's project selection differs, set it via the same mechanism the other workshop controller tests use to pick a current project.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/workshop/configuration_integrations_test.rb`
Expected: FAIL — params not handled / columns not written.

- [ ] **Step 3: Controller — branch integrations save by `integration` param**

In `update_integrations_settings`, replace the body to dispatch on `params[:integration]`:
```ruby
  def update_integrations_settings
    case params[:integration]
    when "jira"   then save_jira_integration
    when "github" then save_github_integration
    else save_workspace_integration   # existing github_repo/token/toggles path (legacy)
    end
  end

  def save_jira_integration
    project = current_workshop_project
    return flash[:alert] = "No project selected." unless project
    attrs = params.require(:project).permit(:jira_site, :jira_email, :jira_api_token)
    attrs.delete(:jira_api_token) if attrs[:jira_api_token].blank?
    if project.update(attrs)
      ProjectMcpConfig.write!(project) if project.workspace_dir.present?
      flash[:clar_toast] = "Jira settings saved"
    else
      flash[:alert] = project.errors.full_messages.to_sentence
    end
  end

  def save_github_integration
    project = current_workshop_project
    return flash[:alert] = "No project selected." unless project
    attrs = params.require(:project).permit(:github_repo, :github_token)
    attrs.delete(:github_token) if attrs[:github_token].blank?
    if project.update(attrs)
      project.ensure_workspace_dir!
      ProjectMcpConfig.write!(project)
      ProjectRepoCheckoutJob.perform_later(project.id)
      flash[:clar_toast] = "GitHub settings saved"
    else
      flash[:alert] = project.errors.full_messages.to_sentence
    end
  end

  def save_workspace_integration
    attrs = integrations_settings_params
    attrs.delete(:github_token) if attrs[:github_token].blank?
    if current_workspace.update(attrs)
      flash[:clar_toast] = "Integration settings saved"
    else
      flash[:alert] = current_workspace.errors.full_messages.to_sentence
    end
  end
```
Keep the existing `integrations_settings_params` (workspace path) untouched.

- [ ] **Step 4: View — make Manage Jira editable**

Replace the read-only Site URL block and the ".env" note in `_manage_jira.html.erb` with a form that submits `integration: "jira"` and `project[jira_site/jira_email/jira_api_token]`:
```erb
<%= form_with url: workshop_configuration_path(tab: "integrations"), method: :patch, data: { turbo: false } do |f| %>
  <%= hidden_field_tag :integration, "jira" %>
  <label class="clar-field-label">SITE URL</label>
  <%= text_field_tag "project[jira_site]", current_workshop_project&.jira_site.presence || ENV["JIRA_DOMAIN"],
        placeholder: "your-company.atlassian.net", class: "clar-input mb-4" %>

  <label class="clar-field-label">EMAIL</label>
  <%= text_field_tag "project[jira_email]", current_workshop_project&.jira_email.presence || ENV["JIRA_EMAIL"],
        placeholder: "you@example.com", class: "clar-input mb-4" %>

  <label class="clar-field-label">API TOKEN</label>
  <%= password_field_tag "project[jira_api_token]", nil,
        placeholder: current_workshop_project&.jira_api_token.present? ? "•••••••••• (leave blank to keep)" : "Not set",
        class: "clar-input mb-4", autocomplete: "off" %>

  <label class="clar-field-label">PROJECT KEY</label>
  <div class="clar-input clar-mono mb-4 flex items-center bg-[var(--surface-2)]"><%= current_workshop_project&.external_reference.presence || "—" %></div>

  <%# keep the existing CUSTOM FIELDS block + Verify fields button here %>

  <div class="flex justify-end gap-2.5">
    <button type="button" class="clar-btn" data-action="clar-modal#close">Cancel</button>
    <%= f.submit "Save changes", class: "clar-btn clar-btn-primary" %>
  </div>
<% end %>
```
Remove the "Credentials are configured on the server (.env)." note.

- [ ] **Step 5: View — persist GitHub to the project**

In `_manage_github.html.erb`, change the form to submit `integration: "github"` and use `project[github_repo]` / `project[github_token]` (falling back to the workspace values for display). Add `<%= hidden_field_tag :integration, "github" %>`. Keep the existing repo/token/branch fields' visual layout; only the field names and hidden integration marker change.

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/workshop/configuration_integrations_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/workshop/configuration_controller.rb app/views/workshop/configuration/_manage_jira.html.erb app/views/workshop/configuration/_manage_github.html.erb test/controllers/workshop/configuration_integrations_test.rb
git commit -m "feat: editable per-project Jira/GitHub creds; regenerate mcp + checkout on save"
```

---

## Task 10: Deploy prerequisites + grandfather elvium

**Files:**
- Modify: `config/deploy.rb` (or a Capistrano task) — pip install + clients base dir
- Docs: append a "Deployment" section to the design spec or a runbook
- No automated test (infra); verified by a manual server checklist below.

**Interfaces:**
- Consumes: everything above.
- Produces: a server where automations actually work end-to-end.

- [ ] **Step 1: Add a Capistrano task to install mcp-atlassian**

In `config/deploy.rb`, add (namespace `deploy`, hooked once — idempotent):
```ruby
namespace :mcp do
  desc "Ensure the Jira MCP server (mcp-atlassian) is installed"
  task :install_jira do
    on roles(:app) do
      execute "pip3 install --user --upgrade mcp-atlassian || true"
    end
  end
end
after "deploy:updated", "mcp:install_jira"
```

- [ ] **Step 2: Ensure Solid Queue PATH can spawn mcp-atlassian and npx**

Confirm the Solid Queue start command sees `~/.local/bin` (pip user bin) and the node bin. In `config/deploy.rb`'s `solid_queue:start`, prefix PATH:
```ruby
execute "PATH=$HOME/.local/bin:/usr/local/bin:$PATH nohup bundle exec rake solid_queue:start > #{shared_path}/log/solid_queue.log 2>&1 &"
```
(Adjust to match the existing solid_queue:start invocation; only the PATH prefix is added.)

- [ ] **Step 3: Create the clients base dir on the server**

One-time (or idempotent in deploy):
```bash
ssh -p 64321 host420646@host420646.hostido.net.pl 'mkdir -p ~/work/clients && chmod 700 ~/work/clients'
```

- [ ] **Step 4: Grandfather the elvium project**

On the server, set the elvium project's `workspace_dir` to the legacy checkout so it is never re-cloned and its automations run there:
```bash
ssh -p 64321 host420646@host420646.hostido.net.pl \
  'cd ~/domains/clar.rubyonsaas.com/app/current && \
   bin/rails runner "p = Project.find_by(external_reference: %q{DEV}) || Project.joins(:alert_rules).first; \
     p.update_column(:workspace_dir, Project::ELVIUM_LEGACY_DIR); \
     puts p.reload.legacy_elvium?"'
```
Expected output: `true`. (Adjust the project lookup to the actual elvium project — likely the one whose alert rules reference elviumcom/elvium.)

- [ ] **Step 5: Verify AR encryption keys on the server**

```bash
ssh -p 64321 host420646@host420646.hostido.net.pl \
  'cd ~/domains/clar.rubyonsaas.com/app/current && \
   bin/rails runner "puts ActiveRecord::Encryption.config.primary_key.present?"'
```
Expected: `true`. If false, add keys to `shared/.env` (or the master key) and restart.

- [ ] **Step 6: End-to-end smoke test on the server**

1. In the UI, open the elvium project's Jira Manage modal, enter site/email/token, Save.
2. Confirm `~/work/elvium/.mcp.json` exists, mode 600, has `github` + `jira` servers:
   ```bash
   ssh -p 64321 host420646@host420646.hostido.net.pl \
     'ls -l ~/work/elvium/.mcp.json && python3 -c "import json;print(list(json.load(open(\"/home/host420646/work/elvium/.mcp.json\"))[\"mcpServers\"].keys()))"'
   ```
   Expected: `['github', 'jira']`, `-rw-------`.
3. Trigger the translation-scan rule (or wait for its schedule). Open the Memory modal — the `<issues>` block should now be empty (or report a real Jira/GitHub error, not "no MCP server connected").
4. Confirm a Jira comment was posted on an in-scope task.

- [ ] **Step 7: Commit**

```bash
git add config/deploy.rb
git commit -m "chore: deploy prerequisites for per-project MCP (mcp-atlassian, PATH, clients dir)"
```

---

## Self-Review Notes

- **Spec coverage:** data model (T2), resolver (T3), GithubClient.for_project (T4), ProjectMcpConfig + folder/perms + legacy helpers (T5), repo checkout (T6), CLI --mcp-config (T7), AlertRuleRunJob wiring (T8), editable UI + triggers (T9), deploy prereqs + grandfather + encryption verify (T1/T10). Error-handling layers are realized across T5 (omit unconfigured server), T6 (checkout error status), T8 (no crash), T9 (blank-preserves).
- **Encryption ordering:** T1 (keys) precedes T2 (`encrypts` columns) — required, or encrypted round-trip fails.
- **Non-break guarantee:** `GithubClient.for` and `PrReviewJob` untouched; `ClaudeCliService` changes are additive (nil mcp_config = old behavior); elvium grandfathered in T10.
- **Server-key exactness:** enforced by test in T5 (`assert servers.key?("github")` / `"jira"`).
- **Local test caveat:** every "run tests" step is intended for the server; where a single test file loads without the pg segfault path locally, it may be run with `ruby -Itest <file>`.
