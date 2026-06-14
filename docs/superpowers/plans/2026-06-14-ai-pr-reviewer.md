# AI PR Reviewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every 7 minutes (09:00–20:00 Warsaw), review new/changed open PRs in a configured GitHub repo with the `claude` CLI (Jira + codebase + git context), posting ≤4 inline comments on first review and ≤2 on later new-commit reviews, with a green/red connection indicator and an admin error banner.

**Architecture:** A `GithubClient` (Net::HTTP, JiraClient pattern) talks to the GitHub REST API with a per-workspace token. A recurring `PrReviewCheckJob` health-checks GitHub, then finds open non-draft PRs whose head SHA changed since last review and enqueues `PrReviewJob` per PR. `PrReviewJob` runs `ClaudeCliService` against the local repo checkout, caps comments, and posts a GitHub review. `PrReview` rows track per-PR state. Status fields on the workspace drive a Settings indicator and an admin-only layout banner.

**Tech Stack:** Rails 8.1.2, Minitest, WebMock (HTTP stubs), Solid Queue (recurring), Net::HTTP, the `claude` CLI via `ClaudeCliService`.

---

## File Structure

- `db/migrate/20260614000002_add_github_settings_to_workspaces.rb` — token/repo/toggle + 3 status columns on `workspaces`.
- `db/migrate/20260614000003_create_pr_reviews.rb` + `app/models/pr_review.rb` — per-PR review state.
- `app/services/github_client.rb` — REST wrapper + `health_check`.
- `app/services/pr_jira_key.rb` — extract a Jira key from branch/title/body.
- `app/jobs/pr_review_check_job.rb` — recurring: health-check + detect work + enqueue.
- `app/jobs/pr_review_job.rb` — per-PR: build context, run claude, cap, post review, record SHA.
- `app/controllers/workspace_settings_controller.rb` — permit github params + `test_github` action.
- `app/controllers/concerns/authorization.rb` (or workspace_scoped) — `github_connection_problem?` helper_method.
- `app/views/workspace_settings/show.html.erb` — GitHub connection card + status dot + Test button.
- `app/views/layouts/application.html.erb` — admin-only red banner.
- `config/routes.rb` — `post :test_github` on workspace_settings.
- `config/recurring.yml` — `pr_review_check` every 7 min, 09–19.
- Tests: `test/services/github_client_test.rb`, `test/services/pr_jira_key_test.rb`, `test/jobs/pr_review_check_job_test.rb`, `test/jobs/pr_review_job_test.rb`, `test/controllers/workspace_settings_controller_test.rb` (append).

### Verified facts
- `JiraClient` uses `Net::HTTP`, `TIMEOUT`, rescue `Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED`. `webmock` available.
- `ClaudeCliService.new(codebase_path:).start_session(prompt:)` → `{ session_id:, response: }`; runs the `claude` CLI with `chdir: codebase_path`. Raises `ClaudeCliService::ClaudeCliError` on CLI-not-found/parse error.
- `Task.find_by(external_reference: "DEV-836")` links Jira; `Task` has `external_reference`.
- `current_workspace`, `can_see_money?` are `helper_method`s (concerns). Layout already renders an impersonation banner at the top of `<body>` gated on `current_user`.
- `workspaces(:one)` exists; `users(:one)` owner/admin, `users(:two)` employee. Settings controller has `require_admin!` and a "blank token keeps existing" pattern (Discord).
- App time zone is Warsaw; recurring cron is evaluated in that zone.

---

### Task 1: Workspace GitHub settings columns

**Files:**
- Create: `db/migrate/20260614000002_add_github_settings_to_workspaces.rb`
- Test: `test/models/workspace_test.rb` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/models/workspace_test.rb` (inside the class):

```ruby
  test "github settings default to nil/false" do
    w = Workspace.create!(name: "GH Co")
    assert_nil w.github_token
    assert_nil w.github_repo
    assert_not w.pr_review_enabled
    assert_nil w.github_status_ok
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/workspace_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'github_token'`.

- [ ] **Step 3: Create the migration**

Create `db/migrate/20260614000002_add_github_settings_to_workspaces.rb`:

```ruby
class AddGithubSettingsToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :github_token, :string
    add_column :workspaces, :github_repo, :string
    add_column :workspaces, :pr_review_enabled, :boolean, null: false, default: false
    add_column :workspaces, :github_status_ok, :boolean
    add_column :workspaces, :github_status_checked_at, :datetime
    add_column :workspaces, :github_status_error, :string
  end
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/workspace_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260614000002_add_github_settings_to_workspaces.rb db/schema.rb test/models/workspace_test.rb
git commit -m "feat: add GitHub PR-reviewer settings columns to workspaces"
```

---

### Task 2: `GithubClient` service

**Files:**
- Create: `app/services/github_client.rb`
- Test: `test/services/github_client_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/github_client_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class GithubClientTest < ActiveSupport::TestCase
  def client
    GithubClient.new(token: "tok", repo: "acme/widgets")
  end

  test "configured? requires token and repo" do
    assert_not GithubClient.new(token: nil, repo: "a/b").configured?
    assert_not GithubClient.new(token: "t", repo: nil).configured?
    assert client.configured?
  end

  test "open_pull_requests parses the list" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls?state=open&per_page=50")
      .with(headers: { "Authorization" => "Bearer tok", "Accept" => "application/vnd.github+json" })
      .to_return(status: 200, body: [ { number: 7, draft: false } ].to_json)
    prs = client.open_pull_requests
    assert_equal 7, prs.first["number"]
  end

  test "create_review posts the review payload and returns true on 200" do
    stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls/7/reviews")
      .with(body: hash_including("event" => "COMMENT", "body" => "🤖 Automated AI review"))
      .to_return(status: 200, body: "{}")
    assert client.create_review(7, body: "🤖 Automated AI review", event: "COMMENT",
      comments: [ { path: "a.rb", line: 3, side: "RIGHT", body: "x" } ])
    assert_requested stub
  end

  test "create_review returns false on error without raising" do
    stub_request(:post, "https://api.github.com/repos/acme/widgets/pulls/7/reviews").to_return(status: 422, body: "{}")
    assert_not client.create_review(7, body: "b", event: "COMMENT", comments: [])
  end

  test "health_check ok on 200" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_return(status: 200, body: "{}")
    assert_equal({ ok: true }, client.health_check)
  end

  test "health_check reports error on 401" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_return(status: 401, body: "{}")
    result = client.health_check
    assert_not result[:ok]
    assert_match(/401/, result[:error])
  end

  test "health_check reports error on network failure" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets").to_raise(SocketError.new("boom"))
    assert_not client.health_check[:ok]
  end

  test ".for builds from a workspace" do
    w = workspaces(:one)
    w.update!(github_token: "t", github_repo: "acme/widgets")
    assert GithubClient.for(w).configured?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/github_client_test.rb`
Expected: FAIL — `uninitialized constant GithubClient`.

- [ ] **Step 3: Implement the service**

Create `app/services/github_client.rb`:

```ruby
require "net/http"
require "json"

# Minimal GitHub REST client for the PR reviewer. Per-workspace token + repo.
# Used inside background jobs (no MCP available there).
class GithubClient
  API_BASE = "https://api.github.com".freeze
  TIMEOUT  = 15

  def self.for(workspace)
    new(token: workspace&.github_token, repo: workspace&.github_repo)
  end

  def initialize(token: nil, repo: nil)
    @token = token
    @repo = repo
  end

  def configured?
    @token.present? && @repo.present?
  end

  def open_pull_requests
    get("/repos/#{@repo}/pulls?state=open&per_page=50") || []
  end

  def pull_request(number)
    get("/repos/#{@repo}/pulls/#{number}")
  end

  def pull_request_commits(number)
    get("/repos/#{@repo}/pulls/#{number}/commits?per_page=100") || []
  end

  def pull_request_files(number)
    get("/repos/#{@repo}/pulls/#{number}/files?per_page=100") || []
  end

  def create_review(number, body:, event:, comments:)
    payload = { event: event, body: body }
    payload[:comments] = comments if comments.present?
    post("/repos/#{@repo}/pulls/#{number}/reviews", payload)
  end

  # Returns { ok: true } or { ok: false, error: "..." }. Never raises.
  def health_check
    response = raw(:get, "/repos/#{@repo}")
    return { ok: true } if response.is_a?(Net::HTTPSuccess)
    { ok: false, error: "#{response.code} #{response.message}" }
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    { ok: false, error: e.message }
  end

  private

  def get(path)
    response = raw(:get, path)
    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, JSON::ParserError => e
    Rails.logger.error("[GithubClient] GET #{path} failed: #{e.message}")
    nil
  end

  def post(path, payload)
    response = raw(:post, path, payload.to_json)
    return true if response.is_a?(Net::HTTPSuccess)
    Rails.logger.error("[GithubClient] POST #{path} failed: #{response.code} #{response.message}")
    false
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.error("[GithubClient] POST #{path} error: #{e.message}")
    false
  end

  def raw(method, path, body = nil)
    uri = URI("#{API_BASE}#{path}")
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "Clar-PR-Reviewer"
    request["Content-Type"] = "application/json" if method == :post
    request.body = body if body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    http.request(request)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/github_client_test.rb`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/github_client.rb test/services/github_client_test.rb
git commit -m "feat: GithubClient REST wrapper with health_check"
```

---

### Task 3: Jira-key extraction

**Files:**
- Create: `app/services/pr_jira_key.rb`
- Test: `test/services/pr_jira_key_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/pr_jira_key_test.rb`:

```ruby
require "test_helper"

class PrJiraKeyTest < ActiveSupport::TestCase
  test "extracts an uppercase key from branch, title, or body" do
    assert_equal "DEV-836", PrJiraKey.extract(branch: "feature/DEV-836-thing", title: "x", body: "")
    assert_equal "DEV-836", PrJiraKey.extract(branch: "x", title: "DEV-836 add stuff", body: "")
    assert_equal "DEV-836", PrJiraKey.extract(branch: "x", title: "y", body: "fixes DEV-836")
  end

  test "is case-insensitive and upcases the result" do
    assert_equal "DEV-836", PrJiraKey.extract(branch: "dev-836-thing", title: "", body: "")
  end

  test "returns nil when no key present" do
    assert_nil PrJiraKey.extract(branch: "feature/cleanup", title: "tidy", body: "no ticket")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/pr_jira_key_test.rb`
Expected: FAIL — `uninitialized constant PrJiraKey`.

- [ ] **Step 3: Implement**

Create `app/services/pr_jira_key.rb`:

```ruby
# Extracts a Jira issue key (e.g. DEV-836) from a PR's branch, title, or body.
module PrJiraKey
  PATTERN = /\b([A-Z][A-Z0-9]+-\d+)\b/i

  def self.extract(branch:, title:, body:)
    [ branch, title, body ].compact.each do |text|
      m = text.match(PATTERN)
      return m[1].upcase if m
    end
    nil
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/services/pr_jira_key_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/services/pr_jira_key.rb test/services/pr_jira_key_test.rb
git commit -m "feat: extract Jira key from PR branch/title/body"
```

---

### Task 4: `PrReview` model + table

**Files:**
- Create: `db/migrate/20260614000003_create_pr_reviews.rb`, `app/models/pr_review.rb`
- Modify: `app/models/workspace.rb`
- Test: `test/models/pr_review_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/pr_review_test.rb`:

```ruby
require "test_helper"

class PrReviewTest < ActiveSupport::TestCase
  test "valid with workspace and pr_number" do
    r = PrReview.new(workspace: workspaces(:one), pr_number: 7)
    assert r.valid?
  end

  test "pr_number unique per workspace" do
    PrReview.create!(workspace: workspaces(:one), pr_number: 7)
    dup = PrReview.new(workspace: workspaces(:one), pr_number: 7)
    assert_not dup.valid?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/pr_review_test.rb`
Expected: FAIL — `uninitialized constant PrReview`.

- [ ] **Step 3: Migration**

Create `db/migrate/20260614000003_create_pr_reviews.rb`:

```ruby
class CreatePrReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :pr_reviews do |t|
      t.references :workspace, null: false, foreign_key: true
      t.integer :pr_number, null: false
      t.string :last_reviewed_sha
      t.boolean :initial_done, null: false, default: false
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :pr_reviews, [ :workspace_id, :pr_number ], unique: true
  end
end
```

- [ ] **Step 4: Model + association**

Create `app/models/pr_review.rb`:

```ruby
class PrReview < ApplicationRecord
  belongs_to :workspace

  validates :pr_number, presence: true, uniqueness: { scope: :workspace_id }
end
```

In `app/models/workspace.rb`, add alongside the other `has_many` lines:

```ruby
  has_many :pr_reviews, dependent: :delete_all
```

- [ ] **Step 5: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/pr_review_test.rb`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260614000003_create_pr_reviews.rb db/schema.rb app/models/pr_review.rb app/models/workspace.rb test/models/pr_review_test.rb
git commit -m "feat: PrReview model tracks per-PR review state"
```

---

### Task 5: `PrReviewJob` — review one PR

**Files:**
- Create: `app/jobs/pr_review_job.rb`
- Test: `test/jobs/pr_review_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/pr_review_job_test.rb`:

```ruby
require "test_helper"

class PrReviewJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", pr_review_enabled: true)
  end

  # Fake GithubClient capturing the review call.
  def fake_github(pr:, files: [ { "filename" => "a.rb", "patch" => "@@ -1 +1 @@\n+code" } ], commits: [])
    fake = Object.new
    captured = {}
    fake.define_singleton_method(:pull_request) { |_n| pr }
    fake.define_singleton_method(:pull_request_files) { |_n| files }
    fake.define_singleton_method(:pull_request_commits) { |_n| commits }
    fake.define_singleton_method(:create_review) { |n, body:, event:, comments:| captured.merge!(n: n, body: body, comments: comments); true }
    fake.define_singleton_method(:captured) { captured }
    fake
  end

  def with_github(fake)
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  def with_ai(json)
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| { session_id: "s", response: json } }
    yield
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  def pr_payload(number: 7, sha: "abc", draft: false)
    { "number" => number, "draft" => draft, "title" => "DEV-836 thing", "body" => "",
      "head" => { "sha" => sha, "ref" => "dev-836-thing" } }
  end

  test "initial review caps at 4 comments and posts a review, recording the SHA" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    ai = [ 1, 2, 3, 4, 5 ].map { |i| { "path" => "a.rb", "line" => i, "comment" => "c#{i}" } }.to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end

    assert_equal 4, fake.captured[:comments].size
    assert_equal "🤖 Automated AI review", fake.captured[:body]
    review = PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_equal "abc", review.last_reviewed_sha
    assert review.initial_done
  end

  test "followup caps at 2 comments" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true)
    fake = fake_github(pr: pr_payload(sha: "new"), commits: [ { "sha" => "new" } ])
    ai = [ 1, 2, 3 ].map { |i| { "path" => "a.rb", "line" => i, "comment" => "c#{i}" } }.to_json

    with_github(fake) do
      with_ai(ai) do
        PrReviewJob.perform_now(@workspace.id, 7, "followup")
      end
    end

    assert_equal 2, fake.captured[:comments].size
    assert_equal "new", PrReview.find_by(workspace: @workspace, pr_number: 7).last_reviewed_sha
  end

  test "no issues posts the no-issues review" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("[]") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_equal "🤖 No issues found 👍", fake.captured[:body]
    assert_nil fake.captured[:comments]
  end

  test "unparseable AI output does not advance the SHA" do
    fake = fake_github(pr: pr_payload(sha: "abc"))
    with_github(fake) do
      with_ai("not json at all") do
        PrReviewJob.perform_now(@workspace.id, 7, "initial")
      end
    end
    assert_nil PrReview.find_by(workspace: @workspace, pr_number: 7)
    assert_empty fake.captured
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/pr_review_job_test.rb`
Expected: FAIL — `uninitialized constant PrReviewJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/pr_review_job.rb`:

```ruby
class PrReviewJob < ApplicationJob
  queue_as :default

  CAPS = { "initial" => 4, "followup" => 2 }.freeze
  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  def perform(workspace_id, pr_number, mode)
    workspace = Workspace.find_by(id: workspace_id)
    return unless workspace

    github = GithubClient.for(workspace)
    return unless github.configured?

    pr = github.pull_request(pr_number)
    return unless pr
    return if pr["draft"] || pr["state"] != "open" && pr["state"].present?

    head_sha = pr.dig("head", "sha")
    files = github.pull_request_files(pr_number)

    issues = ai_issues(pr, files, mode)
    return if issues.nil? # parse failure → do not advance SHA, retry next cycle

    issues = issues.first(CAPS.fetch(mode, 4))
    post_review(github, pr_number, issues)

    record = PrReview.find_or_initialize_by(workspace_id: workspace.id, pr_number: pr_number)
    record.update!(last_reviewed_sha: head_sha, initial_done: true, reviewed_at: Time.current)
  end

  private

  # Returns an array of {path,line,comment} hashes, or nil if the AI output
  # couldn't be parsed (so the caller can avoid marking the PR reviewed).
  def ai_issues(pr, files, mode)
    prompt = build_prompt(pr, files, mode)
    response = ClaudeCliService.new(codebase_path: PrReviewJob::CODEBASE_PATH).start_session(prompt: prompt)[:response]
    parsed = JSON.parse(extract_json(response))
    return nil unless parsed.is_a?(Array)
    parsed.filter_map do |h|
      next unless h.is_a?(Hash) && h["path"].present? && h["line"] && h["comment"].present?
      { path: h["path"], line: h["line"].to_i, comment: h["comment"].to_s }
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[PrReviewJob] claude error: #{e.message}")
    nil
  rescue JSON::ParserError
    nil
  end

  # Pull the first JSON array out of the response (the CLI may wrap prose around it).
  def extract_json(text)
    text.to_s[/\[.*\]/m] || text.to_s
  end

  def build_prompt(pr, files, mode)
    key = PrJiraKey.extract(branch: pr.dig("head", "ref"), title: pr["title"], body: pr["body"])
    task = key ? Task.find_by(external_reference: key) : nil
    ticket = if task
      "Linked Jira ticket #{key}:\nTitle: #{task.name}\nDescription: #{task.description}"
    else
      "No linked Jira ticket."
    end
    cap = CAPS.fetch(mode, 4)
    diff = files.map { |f| "FILE: #{f['filename']}\n#{f['patch']}" }.join("\n\n")
    <<~PROMPT
      You are reviewing a GitHub pull request. Use the repository in the current
      working directory (you may read files and run `git log`/`git blame`).

      #{ticket}

      Changed files and diffs:
      #{diff}

      Return ONLY a JSON array of at most #{cap} items, each the MOST important
      issue: {"path": "<file>", "line": <line number in the new file>,
      "comment": "<concise, actionable review comment>"}. Prioritise correctness,
      security, data integrity, and missed acceptance criteria. Skip style nits.
      If nothing important, return [].
    PROMPT
  end

  def post_review(github, pr_number, issues)
    if issues.empty?
      github.create_review(pr_number, body: "🤖 No issues found 👍", event: "COMMENT", comments: [])
    else
      comments = issues.map { |i| { path: i[:path], line: i[:line], side: "RIGHT", body: i[:comment] } }
      github.create_review(pr_number, body: "🤖 Automated AI review", event: "COMMENT", comments: comments)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/pr_review_job_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/pr_review_job.rb test/jobs/pr_review_job_test.rb
git commit -m "feat: PrReviewJob runs claude review and posts capped comments"
```

---

### Task 6: `PrReviewCheckJob` — recurring detector

**Files:**
- Create: `app/jobs/pr_review_check_job.rb`
- Test: `test/jobs/pr_review_check_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/pr_review_check_job_test.rb`:

```ruby
require "test_helper"

class PrReviewCheckJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", pr_review_enabled: true)
  end

  def fake_github(prs:, health: { ok: true })
    fake = Object.new
    fake.define_singleton_method(:configured?) { true }
    fake.define_singleton_method(:health_check) { health }
    fake.define_singleton_method(:open_pull_requests) { prs }
    fake.define_singleton_method(:pull_request) { |n| prs.find { |p| p["number"] == n } }
    fake
  end

  def with_github(fake)
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }
    yield
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  def pr(number, sha, draft: false)
    { "number" => number, "draft" => draft, "head" => { "sha" => sha } }
  end

  test "enqueues initial review for an unseen PR" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      fake = fake_github(prs: [ pr(7, "abc") ])
      with_github(fake) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "initial" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "enqueues followup when head SHA changed" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "old", initial_done: true)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      fake = fake_github(prs: [ pr(7, "new") ])
      with_github(fake) do
        assert_enqueued_with(job: PrReviewJob, args: [ @workspace.id, 7, "followup" ]) do
          PrReviewCheckJob.perform_now
        end
      end
    end
  end

  test "skips unchanged PR" do
    PrReview.create!(workspace: @workspace, pr_number: 7, last_reviewed_sha: "same", initial_done: true)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "same") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "skips drafts" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc", draft: true) ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "skips scan and records failure when health check fails" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ], health: { ok: false, error: "401 Unauthorized" })) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
    @workspace.reload
    assert_not @workspace.github_status_ok
    assert_equal "401 Unauthorized", @workspace.github_status_error
  end

  test "records healthy status" do
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [])) { PrReviewCheckJob.perform_now }
    end
    assert @workspace.reload.github_status_ok
  end

  test "no-op outside working hours" do
    travel_to Time.zone.local(2026, 6, 15, 21, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end

  test "no-op when disabled" do
    @workspace.update!(pr_review_enabled: false)
    travel_to Time.zone.local(2026, 6, 15, 10, 0) do
      with_github(fake_github(prs: [ pr(7, "abc") ])) do
        assert_no_enqueued_jobs(only: PrReviewJob) { PrReviewCheckJob.perform_now }
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/pr_review_check_job_test.rb`
Expected: FAIL — `uninitialized constant PrReviewCheckJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/pr_review_check_job.rb`:

```ruby
class PrReviewCheckJob < ApplicationJob
  queue_as :default

  WINDOW = (9...20) # 09:00–19:59 local

  def perform
    return unless WINDOW.cover?(Time.current.hour)

    Workspace.where(pr_review_enabled: true).find_each do |workspace|
      github = GithubClient.for(workspace)
      next unless github.configured?

      health = github.health_check
      workspace.update_columns(
        github_status_ok: health[:ok],
        github_status_error: health[:error],
        github_status_checked_at: Time.current
      )
      next unless health[:ok]

      github.open_pull_requests.each do |pr|
        next if pr["draft"]
        number = pr["number"]
        head_sha = pr.dig("head", "sha")
        record = PrReview.find_by(workspace_id: workspace.id, pr_number: number)

        if record.nil?
          PrReviewJob.perform_later(workspace.id, number, "initial")
        elsif record.last_reviewed_sha != head_sha
          PrReviewJob.perform_later(workspace.id, number, "followup")
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/jobs/pr_review_check_job_test.rb`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add app/jobs/pr_review_check_job.rb test/jobs/pr_review_check_job_test.rb
git commit -m "feat: PrReviewCheckJob health-checks and enqueues PR reviews"
```

---

### Task 7: Settings — params, Test connection, status; routes

**Files:**
- Modify: `config/routes.rb`, `app/controllers/workspace_settings_controller.rb`, `app/controllers/concerns/authorization.rb`
- Test: `test/controllers/workspace_settings_controller_test.rb` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/workspace_settings_controller_test.rb` (inside the class):

```ruby
  test "admin can save GitHub settings; blank token keeps existing" do
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { github_token: "ghp_x", github_repo: "acme/widgets", pr_review_enabled: "1" } }
    @workspace.reload
    assert_equal "ghp_x", @workspace.github_token
    assert_equal "acme/widgets", @workspace.github_repo
    assert @workspace.pr_review_enabled

    patch workspace_settings_path, params: { workspace: { github_token: "", github_repo: "acme/other" } }
    @workspace.reload
    assert_equal "ghp_x", @workspace.github_token, "blank token keeps existing"
    assert_equal "acme/other", @workspace.github_repo
  end

  test "test_github runs a health check and stores the result" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets")
    fake = Object.new
    fake.define_singleton_method(:health_check) { { ok: false, error: "401 Unauthorized" } }
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }
    sign_in_as(users(:one))
    post test_github_workspace_settings_path
    assert_redirected_to workspace_settings_path
    @workspace.reload
    assert_not @workspace.github_status_ok
    assert_equal "401 Unauthorized", @workspace.github_status_error
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  test "employee cannot run test_github" do
    sign_in_as(users(:two))
    post test_github_workspace_settings_path
    assert_redirected_to root_path
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: FAIL — no `test_github_workspace_settings_path` route / not permitted.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, change the workspace_settings line to:

```ruby
  resource :workspace_settings, only: [ :show, :update ] do
    post :test_github, on: :collection
  end
```

(For a singular `resource`, `on: :collection` yields `/workspace_settings/test_github` with helper `test_github_workspace_settings_path`.)

- [ ] **Step 4: Permit params + add the action**

In `app/controllers/workspace_settings_controller.rb`, update `workspace_settings_params`:

```ruby
  def workspace_settings_params
    permitted = params.require(:workspace).permit(
      :clients_enabled, :discord_channel_id, :discord_user_token,
      :github_repo, :github_token, :pr_review_enabled
    )
    permitted.delete(:discord_user_token) if permitted[:discord_user_token].blank?
    permitted.delete(:github_token) if permitted[:github_token].blank?
    permitted
  end
```

Add the action (above `private`):

```ruby
  def test_github
    result = GithubClient.for(current_workspace).health_check
    current_workspace.update_columns(
      github_status_ok: result[:ok],
      github_status_error: result[:error],
      github_status_checked_at: Time.current
    )
    notice = result[:ok] ? "GitHub connection OK." : "GitHub connection failed: #{result[:error]}"
    redirect_to workspace_settings_path, notice: notice
  end
```

- [ ] **Step 5: Add the helper for the banner**

In `app/controllers/concerns/authorization.rb`, add to the `helper_method` list `:github_connection_problem?` and define it:

```ruby
  def github_connection_problem?
    current_workspace&.github_token.present? && current_workspace.github_status_ok == false
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/workspace_settings_controller.rb app/controllers/concerns/authorization.rb test/controllers/workspace_settings_controller_test.rb
git commit -m "feat: GitHub settings params, Test connection action, banner helper"
```

---

### Task 8: Settings UI (connection card + status dot) and admin banner

**Files:**
- Modify: `app/views/workspace_settings/show.html.erb`, `app/views/layouts/application.html.erb`
- Test: `test/controllers/workspace_settings_controller_test.rb` (append render checks)

- [ ] **Step 1: Write the failing render tests**

Append inside the test class:

```ruby
  test "settings page shows a red GitHub status when last check failed" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", github_status_ok: false, github_status_error: "401 Unauthorized")
    sign_in_as(users(:one))
    get workspace_settings_path
    assert_response :success
    assert_match "GitHub", response.body
    assert_match "401 Unauthorized", response.body
  end

  test "admin sees the GitHub error banner app-wide when connection is broken" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", github_status_ok: false, github_status_error: "401 Unauthorized")
    sign_in_as(users(:one))
    get time_entries_path
    assert_match "can't reach GitHub", response.body
  end

  test "employee does not see the GitHub error banner" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets", github_status_ok: false, github_status_error: "401")
    sign_in_as(users(:two))
    get time_entries_path
    assert_no_match "can't reach GitHub", response.body
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb -n "/GitHub/"`
Expected: FAIL — the markup isn't present yet.

- [ ] **Step 3: Add the GitHub connection card to settings**

In `app/views/workspace_settings/show.html.erb`, inside the main workspace `form_with` (after the Discord connection card, before the form's submit), add:

```erb
    <div class="m3-card-elevated p-6 space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold" style="color: var(--color-on-surface)">GitHub PR reviewer</h2>
        <% if current_workspace.github_status_ok.nil? %>
          <span class="text-xs" style="color: var(--color-outline)">● not checked yet</span>
        <% elsif current_workspace.github_status_ok %>
          <span class="text-xs" style="color: #16A34A">● Connected<%= " (checked #{time_ago_in_words(current_workspace.github_status_checked_at)} ago)" if current_workspace.github_status_checked_at %></span>
        <% else %>
          <span class="text-xs" style="color: #DC2626">● <%= current_workspace.github_status_error.presence || "Connection failed" %></span>
        <% end %>
      </div>

      <label class="flex items-center justify-between gap-4 cursor-pointer">
        <span class="text-sm font-medium" style="color: var(--color-on-surface)">Enable PR reviewer</span>
        <%= f.check_box :pr_review_enabled, class: "m3-checkbox" %>
      </label>
      <div class="space-y-1">
        <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Repository (owner/repo)</label>
        <%= f.text_field :github_repo, class: "m3-text-field w-full", placeholder: "RubyOnSaas-wiki/clar" %>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">
          GitHub token <%= current_workspace.github_token.present? ? "(set — leave blank to keep)" : "(not set)" %>
        </label>
        <%= f.password_field :github_token, value: "", autocomplete: "off",
              placeholder: current_workspace.github_token.present? ? "••••••••" : "",
              class: "m3-text-field w-full" %>
      </div>
    </div>
```

After the workspace form (`<% end %>` of the main `form_with`), add the Test-connection button (its own form so it doesn't submit the settings form):

```erb
  <% if current_workspace.github_token.present? %>
    <%= button_to "Test GitHub connection", test_github_workspace_settings_path,
          method: :post, class: "m3-btn m3-btn-text m3-btn-sm" %>
  <% end %>
```

- [ ] **Step 4: Add the admin banner to the layout**

In `app/views/layouts/application.html.erb`, right after the impersonation banner block (after its closing `<% end %>`, before `<% if current_user && Current.workspace %>`), add:

```erb
    <% if current_user && Current.workspace && current_user.admin_or_owner?(Current.workspace) && github_connection_problem? %>
      <div class="flex items-center justify-center gap-2 px-4 py-2" style="background: #DC2626; color: white; font-size: 13px;">
        <span>⚠️ PR reviewer can't reach GitHub: <%= Current.workspace.github_status_error.presence || "connection failed" %>. Check the token in <%= link_to "Workspace Settings", workspace_settings_path, style: "color: white; text-decoration: underline;" %>.</span>
      </div>
    <% end %>
```

- [ ] **Step 5: Run tests + build CSS**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS (all, including the GitHub render/banner tests).

Run: `bin/rails tailwindcss:build`
Expected: builds without error.

- [ ] **Step 6: Commit**

```bash
git add app/views/workspace_settings/show.html.erb app/views/layouts/application.html.erb test/controllers/workspace_settings_controller_test.rb
git commit -m "feat: GitHub connection card, status dot, and admin error banner"
```

---

### Task 9: Schedule + regression + deploy

**Files:**
- Modify: `config/recurring.yml`

- [ ] **Step 1: Add the recurring schedule**

In `config/recurring.yml`, under `production:`, add:

```yaml
  pr_review_check:
    class: PrReviewCheckJob
    schedule: "*/7 9-19 * * *"
```

- [ ] **Step 2: Validate + run the new-feature tests**

Run: `ruby -ryaml -e 'YAML.load_file("config/recurring.yml")'`
Then: `bin/rails test test/services/github_client_test.rb test/services/pr_jira_key_test.rb test/models/pr_review_test.rb test/jobs/pr_review_job_test.rb test/jobs/pr_review_check_job_test.rb test/controllers/workspace_settings_controller_test.rb test/models/workspace_test.rb`
Expected: all PASS.

- [ ] **Step 3: Full regression**

Run: `bin/rails test test/controllers test/models test/jobs test/services`
Expected: no NEW failures beyond the known pre-existing ones (holiday overlap, claude_cli `--add-dir` ×3, jira_sync `fetch_all_comments`).

- [ ] **Step 4: Push and deploy**

```bash
git add config/recurring.yml
git commit -m "feat: schedule PR review check every 7 min, 09-20 Warsaw"
git push origin production
cap production deploy
```

Expected: deploy exits 0; both new migrations run; full puma restart.

- [ ] **Step 5: Configure + verify on production**

- In Workspace Settings, enter `github_repo` (e.g. `RubyOnSaas-wiki/clar`), paste a GitHub PAT with `repo` scope, enable the toggle, Save.
- Click **Test GitHub connection** → expect green "Connected". Enter a bad token to confirm red status + the admin banner appears, then restore the good token.
- Confirm `PR_REVIEW_CODEBASE_PATH` (or the default `~/work/elvium`) on the server points at a checkout of the configured repo so the AI has codebase/git context. If the configured repo differs from that checkout, set `PR_REVIEW_CODEBASE_PATH` in the server environment to the correct clone.
- Optionally trigger once: `bin/rails runner "PrReviewCheckJob.perform_now"` and confirm a review appears on an open PR.

---

## Notes for the implementer

- No MCP anywhere — GitHub via REST, AI via the `claude` CLI against a local checkout.
- The `claude` CLI must be able to read the configured repo. `PR_REVIEW_CODEBASE_PATH` (default `~/work/elvium`) must be a clone of `github_repo`; if you watch a different repo, set that env var on the server.
- Comment caps are enforced in `PrReviewJob` (`first(cap)`), independent of the prompt.
- SHA only advances after a successful post; AI parse failures leave the PR to retry next cycle.
- Token is plaintext in the DB (accepted, same as the Discord token); use a `repo`-scoped PAT and rotate as needed.
