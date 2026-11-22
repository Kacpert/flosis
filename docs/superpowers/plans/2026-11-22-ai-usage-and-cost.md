# AI Usage and Cost per Organization (SCRUM-70) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record and price every Claude CLI run, and show each organization what it spent
(item and area figures, Consumption). Give Flosis staff Plans, Models & prices and an
Organizations billing view in a reworked `/hidmin`.

**Architecture:**
- `ClaudeCliService` gets a required `attribution:` and records every run through
  `AiRun::Recorder`:
  - a `running` row is written at start;
  - the row is finished in an `ensure`;
  - a sweeper fails rows a dead process left behind.
- Stops and timeouts send SIGINT first, so the CLI still prints its result and cost.
- Read side: an `AiCosts` query object (one grouped query per page) plus an
  `AiCostFormatter`.
- UI: ERB ports of the accepted designs in `RubyOnSaas-wiki/flosis-app-design@ed2d5e9`,
  with € replaced by $.

**Tech Stack:** Rails 8.1, Ruby 3.4, PostgreSQL, Minitest, Hotwire (Turbo + Stimulus),
Tailwind/`clar-*` classes, SolidQueue recurring jobs.

**Spec:** `docs/superpowers/specs/2026-11-22-ai-usage-and-cost-design.md`. Read it first;
section numbers below (§N) refer to it. Ticket: `tasks/SCRUM-70/scrum-70.md`.

**Designs:** clone `git@github.com:RubyOnSaas-wiki/flosis-app-design.git`, check out
`ed2d5e9`, and serve it with `python3 -m http.server` (`file://` does not work). The
screens are:
- `designs/admin/consumption*.html`
- `designs/admin/configuration*.html`
- `designs/admin/profile*.html`
- `designs/admin/{pipeline,process,process-alerts,process-estimate,bugs,designs-thread,designs-imports,designs-import-built,idea*}.html`
- `designs/flosis-admin/*.html`

Components are under `components/`.

## Global Constraints

- **Money.** All money is US dollars, shown as `$1,234.56`, on every screen. Never `€`, and
  no currency conversion anywhere.
- **Cost and price.**
  - Cost is the CLI's `total_cost_usd`, never computed from the price list.
  - Price is `cost × (1 + margin/100)`, rounded to 6 places, written once and never
    recomputed.
- **Margin of a run.**
  - Own-key runs have a nil margin and a price equal to their cost.
  - Otherwise the margin is `workspace.ai_plan&.margin_percent`, or
    `ENV.fetch("FLOSIS_DEFAULT_MARGIN_PERCENT", "30")` when there is no plan.
- **Months.** A month is a calendar month in `Time.zone` (Warsaw). A run belongs to the
  month of its `ran_at`.
- **Unknown cost.** A run with no reported cost has `cost_usd: nil`. It shows `unknown`,
  and no sum counts it as 0.
- **What counts.**
  - Rows with `status: "running"` are in no list and no sum.
  - Own-key runs are in no total, no limit and no area figure. They are shown apart.
- **Recording never raises into a run.** Every `AiRun::Recorder` method rescues
  `StandardError` and calls `Rails.error.report`.
- **Who sees what.**
  - Cost and margin: `/hidmin` only (Flosis staff).
  - Organizations see price.
- **Item and area figures** are drawn only when `current_workspace.ai_costs_enabled? &&
  current_user.show_ai_costs?`. They are muted, take no new line, card or link, and ride on
  existing rows (see the designs).
- **Consumption** is for `workspace_admin?` only; anyone else gets a 404. It ignores both
  cost switches.
- **Commits.**
  - Commit on `feat/scrum-70-add-token-calculations` in the worktree only. Check
    `git branch --show-current` before every commit.
  - `git add` explicit paths.
  - **No `Co-Authored-By` or other Claude trailer** in any commit message.
- **Tests.** Run them against a private DB. Set
  `DATABASE_URL=postgres://localhost/gold_test_scrum70` (Task 0 creates it). A single file
  is `bin/rails test test/path_test.rb`; the full suite is `PARALLEL_WORKERS=1 bin/rails
  test`. Known date-dependent failures are not regressions: `reports_controller`,
  `holiday_request` and `workshop_report`.

## Review Focus

1. **A run interrupted mid-stream.** This covers Designs Stop, a timeout, and a chat whose
   browser went away. The run must still get a row with its tokens and, after SIGINT, its
   cost. Tests: Task 3 "stopped stream run records INT result cost", "timeout records
   timed_out with cost", and "chat client gone keeps draining and records the result".
2. **A deploy killing a job mid-run.** No `ensure` runs, so the `running` row must be
   swept to `failed` with unknown cost. Test: Task 2 "sweeper fails stale running rows".
3. **A plan edited or reassigned after a month closed.** The closed month must keep its
   limit and plan name. Test: Task 13 "editing a plan leaves last month's limit".
4. **An item deleted after its runs.** Its runs stay in the area, project and organization
   totals and show DELETED in run lists. Tests: Task 7 "deleted item stays in totals" and
   Task 11 "run list marks a deleted item".
5. **A project with both own-key and Flosis-login runs** (Designs on its key, chats on
   Flosis). Its own-key part must stay out of totals while the rest counts. Test: Task 7
   "mixed project splits own key from totals".

---

### Task 0: Workspace setup

**Files:** none (environment only)

- [ ] **Step 1: Bring production in.** Run `git fetch origin && git merge --no-edit
  origin/production` in the worktree. The branch was cut from `main`, which lags
  `production`.
  Expected: a clean merge. Resolve conflicts if any, keeping production's side for files
  this plan does not touch.
- [ ] **Step 2: Make the private test DB.** Run
  `RAILS_ENV=test DATABASE_URL=postgres://localhost/gold_test_scrum70 bin/rails db:create db:schema:load`.
  Expected: no error.
- [ ] **Step 3: Build Tailwind.** Run `bin/rails tailwindcss:build`.
  Expected: `app/assets/builds/tailwind.css` exists.
- [ ] **Step 4: Baseline.** Run
  `DATABASE_URL=postgres://localhost/gold_test_scrum70 bin/rails test test/services/claude_cli_service_test.rb`.
  Expected: `59 runs`, 0 failures.

---

### Task 1: Billing data model

**Files:**
- Create: `db/migrate/20261122100000_create_ai_billing.rb`
- Create: `app/models/ai_run.rb`, `app/models/ai_plan.rb`, `app/models/ai_plan_model.rb`,
  `app/models/ai_model.rb`, `app/models/ai_month_limit.rb`
- Modify: `app/models/workspace.rb`, `app/models/project.rb`, `app/models/user.rb`
- Test: `test/models/ai_run_test.rb`, `test/models/ai_model_test.rb`,
  `test/models/ai_month_limit_test.rb`
- Fixtures: `test/fixtures/ai_plans.yml` (`scale`: monthly 1200, margin 30), empty
  `ai_runs.yml`, `ai_models.yml` and `ai_month_limits.yml`

**Interfaces:**
- Produces:
  - **Tables and columns** exactly as spec §1:
    - `ai_runs` includes `unknown_reviewed_at` and `unknown_reviewed_by_id`;
    - `workspaces` gets `ai_plan_id`, `ai_plan_assigned_at` and `ai_costs_enabled`
      (default true);
    - `users` gets `show_ai_costs` (default false).
  - **`AiRun` constants.**
    - `AiRun::AREAS`, an ordered Hash: `{"task_conversations"=>"Task conversations",
      "designs"=>"Designs and imports", "pr_reviews"=>"PR reviews",
      "estimates"=>"AI estimates", "agents"=>"Agents and alerts",
      "bug_analysis"=>"Bug analysis", "feature_scan"=>"Project feature scan",
      "ticket_chat"=>"Chat with AI on a ticket"}`.
    - `AiRun::STATUSES = %w[running succeeded failed stopped timed_out]`.
    - `AiRun::STALE_AFTER = 3.hours`.
  - **`AiRun` methods and scopes.**
    - `AiRun.default_margin_percent -> BigDecimal`.
    - Scopes: `finished`, `billable` (finished, not own key), `own_keyed` (finished, own
      key), `in_month(date)`, `in_area(area)`, `unknown_cost` (finished, cost nil),
      `unreviewed_unknown`.
    - `AiRun#item_deleted? -> Boolean`: `item_type` is present and `item` is nil.
    - `AiRun#cache_tokens -> Integer`: read + write.
  - **`AiPlan`.**
    - `has_many :ai_plan_models` and `has_many :ai_models, through:`.
    - `has_many :workspaces, foreign_key: :ai_plan_id, dependent: :restrict_with_error`.
    - Validates a present name, `monthly_price_usd >= 0`, and `margin_percent` between 0
      and 1000.
  - **`AiModel`.**
    - `AiModel.name_for(model_id) -> String`.
    - `AiModel.normalize_id(raw) -> String`: strips a `[...]` suffix.
    - `AiModel.seed!`: find-or-create `claude-opus-5-5`, `claude-sonnet-5-5` and
      `claude-haiku-5-5`.
    - `AiModel.register!(model_id)`: find-or-create, nil-safe.
    - `#in_use? -> Boolean`: in any plan.
  - **`AiMonthLimit`.**
    - `AiMonthLimit.ensure_current!(workspace)`: insert this month's row from the live plan
      if missing.
    - `AiMonthLimit.refresh_current!(workspace)`: upsert this month's row from the live
      plan.
    - `AiMonthLimit.for(workspace, month) -> AiMonthLimit or nil`. In the current month,
      with no row yet, it returns an unsaved row built from the live plan.
  - **Associations.**
    - `Workspace`: `belongs_to :ai_plan, optional: true`,
      `has_many :ai_runs, dependent: :delete_all` and
      `has_many :ai_month_limits, dependent: :delete_all`.
    - `Project`: `has_many :ai_runs, dependent: :nullify`.
    - `User`: `has_many :started_ai_runs, class_name: "AiRun",
      foreign_key: :started_by_id, dependent: :nullify`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/ai_run_test.rb
test "areas keep Consumption's order and words" do
  assert_equal "Task conversations", AiRun::AREAS.values.first
  assert_equal "Chat with AI on a ticket", AiRun::AREAS.values.last
  assert_equal 8, AiRun::AREAS.size
end
test "default margin is 30 unless the env says otherwise" do
  assert_equal BigDecimal("30"), AiRun.default_margin_percent
  ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"] = "25"
  assert_equal BigDecimal("25"), AiRun.default_margin_percent
ensure
  ENV.delete("FLOSIS_DEFAULT_MARGIN_PERCENT")
end
test "billable leaves out running and own key; in_month uses Warsaw months" do
  # rows: succeeded 2026-10-31 23:30 Warsaw, running, own_key succeeded
  # assert billable.in_month(Date.new(2026,10,1)) has only the first
end
test "a run whose item was deleted says so" # item_type "PrReview", item_id 0 → item_deleted? true
test "deleting a project keeps its runs" # project.destroy → run.reload.project_id nil, project_name kept
```

```ruby
# test/models/ai_model_test.rb
test "names models the way people say them" do
  assert_equal "Claude Opus 5.5", AiModel.name_for("claude-opus-5-5")
  assert_equal "Claude Haiku 4.5", AiModel.name_for("claude-haiku-4-5-20251001")
  assert_equal "Claude Opus 5", AiModel.name_for("claude-opus-5")
end
test "normalize_id drops the context suffix" do
  assert_equal "claude-opus-5", AiModel.normalize_id("claude-opus-5[1m]")
end
```

```ruby
# test/models/ai_month_limit_test.rb
test "ensure_current! freezes the plan that stands now and never overwrites" # assign scale, ensure → limit 1200; plan price → 1500; ensure again → still 1200
test "refresh_current! follows a plan change this month only" # last month row 1200 stays, this month → 1500
test "for a current month without a row builds one from the live plan"
test "for a past month without a row is nil"
```

- [ ] **Step 2:** Run `bin/rails test test/models/ai_run_test.rb test/models/ai_model_test.rb test/models/ai_month_limit_test.rb`.
  Expected: FAIL (uninitialized constant AiRun).
- [ ] **Step 3: Write the migration and models.**
  - Indexes as spec §1.
  - FKs: `ai_runs.workspace_id`; `ai_runs.project_id` with `on_delete: :nullify`;
    `ai_runs.started_by_id` and `unknown_reviewed_by_id` to `users`, both
    `on_delete: :nullify`; `workspaces.ai_plan_id`; `ai_plan_models` to both tables.
  - Unique indexes: `ai_models.model_id`, `ai_plan_models [ai_plan_id, ai_model_id]` and
    `ai_month_limits [workspace_id, month]`.
  - **There is no FK on `item_id`.**
  - Run `bin/rails db:migrate` and commit `db/schema.rb`.
- [ ] **Step 4:** Run the three test files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: billing tables for AI runs, plans, models and month limits`.

---

### Task 2: Attribution, usage, recorder and sweeper

**Files:**
- Create: `app/models/ai_run/attribution.rb`, `app/models/ai_run/usage.rb`,
  `app/models/ai_run/recorder.rb`, `app/jobs/ai_runs/sweep_job.rb`
- Modify: `config/recurring.yml` (production: `ai_runs_sweep`, class `AiRuns::SweepJob`,
  `every 15 minutes`)
- Test: `test/models/ai_run/attribution_test.rb`, `test/models/ai_run/usage_test.rb`,
  `test/models/ai_run/recorder_test.rb`, `test/jobs/ai_runs/sweep_job_test.rb`

**Interfaces:**
- Consumes: Task 1 models.
- Produces:
  - **`AiRun::Attribution`.**
    - It is `Data.define(:workspace, :project, :area, :item, :item_label, :started_by,
      :automation)`.
    - Its initializer raises `ArgumentError` unless the area is in `AiRun::AREAS`, the
      workspace is present, and exactly one of `started_by` and `automation` is present.
  - **`AiRun::Attribution.task_key(task) -> String`**: `task.external_reference.presence ||
    "task-#{task.id}"`.
  - **Factories, all returning `AiRun::Attribution`:**
    - `for_task_chat(task, purpose:, user:)`:

      | purpose | area | label |
      |---|---|---|
      | `brief` | `task_conversations` | `"KEY · Briefing"` |
      | `refine`, task in pipeline | `task_conversations` | `"KEY · Details Gathering"` |
      | `refine`, otherwise | `ticket_chat` | `"KEY · Chat"` |
      | `breakdown` | `estimates` | `"KEY · Breakdown"` |

    - `for_handoff(task, user:)`: task_conversations, `"KEY · Handoff"`.
    - `for_pr_review(review)`: pr_reviews, `"##{n} #{pr_title}"`, automation
      `"PR review"`.
    - `for_estimate(task, user: nil)`: estimates, `"KEY #{task.name}"`, automation
      `"AI estimate"` when there is no user.
    - `for_delivered_estimate(issue)`: estimates, `"#{jira_key} #{title}"`, automation
      `"AI estimate backfill"`.
    - `for_alert_rule(rule, user: nil)`: agents, `"Rule · #{rule.name}"`, automation
      `rule.name` when there is no user.
    - `for_bug_analysis(bug, user: nil)`: bug_analysis, `"#{jira_key}"`, plus the task's
      name when there is one; automation `"Bug analysis"` when there is no user.
    - `for_feature_scan(project, user: nil)`: feature_scan,
      `"Feature scan · #{project.github_repo.presence || project.name}"`, automation
      `"Feature scan"` when there is no user.
    - `for_design_turn(turn)`: designs; started by `turn.chat_message.user`.
      - When `turn.chat_session.purpose == "designs_setup"`: item `design_setup`, label
        `"Import · Designs from the app, #{I18n.l(setup.created_at.to_date, format: "%-d %b")}"`.
      - Otherwise: item `design_thread`, label `"Thread · #{thread.title}"`.
      - Legacy purpose `designs` (thread nil): item the task, label `"KEY · Designs"`.
    - `for_describe(turn, user:)`: designs, item the thread.
    - In all of them, workspace is `project.workspace` and project is the record's project.
- **`AiRun::Usage`** gathers what a run reported.
  - `#see(event)` takes a Hash CLI event.
  - `#result -> Hash or nil`.
  - `#totals -> Hash` with the keys `input_tokens output_tokens cache_write_tokens
    cache_read_tokens cost_usd model model_usage claude_session_id`.
  - `#any? -> Boolean`.
- **`AiRun::Recorder`.**
  - `start!(attribution, own_key:) -> AiRun or nil`.
  - `progress!(run, usage)`: saves tokens only; at most once per 30 s per run.
  - `finish!(run, usage, status:, duration_ms:) -> AiRun or nil`.
- **`AiRuns::SweepJob#perform`**: running rows older than `AiRun::STALE_AFTER` become
  `failed` with `cost_usd` nil.

- [ ] **Step 1: Write the failing tests**

```ruby
# attribution_test.rb
test "brief on a pipeline task is a task conversation, breakdown counts as an estimate" do
  task = tasks(:jira_task); task.update!(in_pipeline: true)
  assert_equal "task_conversations", AiRun::Attribution.for_task_chat(task, purpose: "brief", user: users(:one)).area
  assert_equal "estimates", AiRun::Attribution.for_task_chat(task, purpose: "breakdown", user: users(:one)).area
end
test "refine is Details Gathering in the pipeline and the ticket chat outside it"
test "an attribution needs a person or an automation, not both" do
  assert_raises(ArgumentError) { AiRun::Attribution.new(workspace: workspaces(:one), project: nil, area: "agents", item: nil, item_label: "x", started_by: users(:one), automation: "Rule") }
end
test "an unknown area is refused"
```

```ruby
# usage_test.rb
RESULT = { "type"=>"result", "session_id"=>"s1", "total_cost_usd"=>0.5, "is_error"=>false,
  "usage"=>{ "input_tokens"=>2, "output_tokens"=>74, "cache_creation_input_tokens"=>16786, "cache_read_input_tokens"=>11842 },
  "modelUsage"=>{ "claude-opus-5[1m]"=>{ "inputTokens"=>10, "outputTokens"=>100, "cacheReadInputTokens"=>1000, "cacheCreationInputTokens"=>500, "costUSD"=>0.45 },
                  "claude-haiku-5-5"=>{ "inputTokens"=>5, "outputTokens"=>20, "cacheReadInputTokens"=>0, "cacheCreationInputTokens"=>0, "costUSD"=>0.05 } } }
test "a result's tokens are the sum over modelUsage and its model the costliest" do
  u = AiRun::Usage.new; u.see(RESULT)
  t = u.totals
  assert_equal 15, t[:input_tokens]; assert_equal 120, t[:output_tokens]
  assert_equal 500, t[:cache_write_tokens]; assert_equal 1000, t[:cache_read_tokens]
  assert_equal BigDecimal("0.5"), t[:cost_usd]; assert_equal "claude-opus-5", t[:model]
end
test "without a result, tokens come from assistant messages, last usage per message id, and cost is nil" do
  u = AiRun::Usage.new
  u.see({ "type"=>"assistant", "message"=>{ "id"=>"m1", "model"=>"claude-opus-5", "usage"=>{ "input_tokens"=>3, "output_tokens"=>5, "cache_read_input_tokens"=>100, "cache_creation_input_tokens"=>10 } } })
  u.see({ "type"=>"assistant", "message"=>{ "id"=>"m1", "model"=>"claude-opus-5", "usage"=>{ "input_tokens"=>3, "output_tokens"=>40, "cache_read_input_tokens"=>100, "cache_creation_input_tokens"=>10 } } })
  u.see({ "type"=>"assistant", "message"=>{ "id"=>"m2", "model"=>"claude-opus-5", "usage"=>{ "input_tokens"=>1, "output_tokens"=>2, "cache_read_input_tokens"=>200, "cache_creation_input_tokens"=>0 } } })
  t = u.totals
  assert_equal 4, t[:input_tokens]; assert_equal 42, t[:output_tokens]; assert_equal 300, t[:cache_read_tokens]
  assert_nil t[:cost_usd]
end
test "a result without modelUsage falls back to its usage block"
```

```ruby
# recorder_test.rb
test "finish prices a run with the plan's margin and freezes the month's limit" do
  ws = workspaces(:one); ws.update!(ai_plan: ai_plans(:scale), ai_plan_assigned_at: Time.current)
  run = AiRun::Recorder.start!(attribution, own_key: false)
  assert_equal "running", run.status
  usage = AiRun::Usage.new.tap { |u| u.see(RESULT) }
  AiRun::Recorder.finish!(run, usage, status: "succeeded", duration_ms: 1200)
  run.reload
  assert_equal BigDecimal("30"), run.margin_percent
  assert_equal BigDecimal("0.65"), run.price_usd
  assert AiMonthLimit.exists?(workspace: ws, month: Date.current.beginning_of_month)
end
test "no plan uses the default margin"
test "own key keeps no margin and its price is its cost"
test "unknown cost stays nil in both cost and price"
test "a model never seen is added to the price list" # AiModel.exists?(model_id: "claude-opus-5")
test "recording errors never raise" do
  AiRun.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
    assert_nil AiRun::Recorder.start!(attribution, own_key: false)
  end
end
```

```ruby
# sweep_job_test.rb
test "sweeper fails stale running rows and leaves fresh ones" do
  stale = AiRun.create!(..., status: "running", ran_at: 4.hours.ago, created_at: 4.hours.ago)
  fresh = AiRun.create!(..., status: "running", ran_at: 10.minutes.ago)
  AiRuns::SweepJob.perform_now
  assert_equal "failed", stale.reload.status; assert_nil stale.cost_usd
  assert_equal "running", fresh.reload.status
end
```

- [ ] **Step 2:** Run the four files.
  Expected: FAIL (uninitialized constants).
- [ ] **Step 3: Implement.**
  - `finish!` also calls `AiMonthLimit.ensure_current!(workspace)` and
    `AiModel.register!(model)`.
  - It rounds the price with `(cost * (1 + margin / 100)).round(6)`.
  - It snapshots `project_name`.
- [ ] **Step 4:** Run the four files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: AI run attribution, usage and recorder, and a sweeper for runs a dead job left`.

---

### Task 3: `ClaudeCliService` records every run

**Files:**
- Modify: `app/services/claude_cli_service.rb`
- Modify: `test/services/claude_cli_service_test.rb` and
  `test/services/claude_cli_service_mcp_test.rb`. Every `ClaudeCliService.new(` gains
  `attribution: test_attribution`, a helper that builds one for `workspaces(:one)` /
  `projects(:jira_project)`, area `agents`, automation `"Test"`.
- Create: `test/services/claude_cli_service_recording_test.rb`
- Create: `test/test_helpers/fake_claude_bin_test_helper.rb`, with
  `with_fake_claude_bin(ruby_source) { ... }`. It writes an executable `claude` script into
  a tmp dir and prepends that dir to `ENV["PATH"]` for the block.

**Interfaces:**
- Consumes: `AiRun::Attribution`, `AiRun::Usage`, `AiRun::Recorder` (Task 2).
- Produces:
  - `ClaudeCliService.new(..., attribution:)` requires an `AiRun::Attribution`; anything
    else raises `ArgumentError`.
  - `ClaudeCliService::StopSignal`, a module. An exception raised from a caller's block
    that includes it makes the run `stopped`.
  - `ClaudeCliService::INT_GRACE_SECONDS = 10`.
  - The public methods keep their signatures and return values.

- [ ] **Step 1: Write the failing tests** in `claude_cli_service_recording_test.rb`. Use
  fake `claude` scripts.

```ruby
test "a json run records tokens, cost and model" do
  with_fake_claude_bin(%(STDIN.read; puts #{RESULT.to_json.inspect})) do
    svc.start_session(prompt: "hi")
  end
  run = AiRun.last
  assert_equal "succeeded", run.status; assert_equal BigDecimal("0.5"), run.cost_usd
  assert_equal "agents", run.area; assert_equal "Test", run.automation
end
test "an is_error result records failed with its cost"
test "a CLI error records failed and re-raises" # script prints nothing → ClaudeCliError, run failed, cost nil
test "timeout records timed_out with cost" do
  # script: trap("INT") { puts RESULT_INT.to_json; exit 0 }; STDIN.read; sleep 30
  # ClaudeCliService.new(timeout: 1, ...).start_session → raises TimeoutError
  # AiRun.last: status "timed_out", cost_usd == RESULT_INT total_cost_usd
end
test "stopped stream run records INT result cost" do
  # script: prints one assistant event line, trap INT → prints result line, else sleeps
  # start_session(prompt:) { |e| raise StopError if e == :tick }   # StopError < StandardError; include ClaudeCliService::StopSignal
  # AiRun.last.status == "stopped", cost from the INT result, input tokens from the result
end
test "a stream run without a result keeps assistant tokens and unknown cost" # script ignores INT and TERM-dies; raise in block
test "chat client gone keeps draining and records the result" do
  # send_initial_streaming with block raising IOError on the first line;
  # the service keeps reading to EOF, records succeeded + cost, then re-raises IOError
end
test "own key is only the project's own key" do
  # project.update!(anthropic_api_key: "sk-own"); api_key: "sk-own" → own_key true; api_key: "sk-other" → false; no key → false
end
test "attribution is required" do
  assert_raises(ArgumentError) { ClaudeCliService.new(codebase_path: "/tmp") }
end
```

- [ ] **Step 2:** Run the new file.
  Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Wrap every public run method in a private `recorded { |usage| ... }`. It calls
    `start!`, then the body, then `finish!` in an `ensure`, with the status as follows:

    | Outcome | Status |
    |---|---|
    | a result with `is_error` false | succeeded |
    | a result with `is_error` true | failed |
    | `TimeoutError` | timed_out |
    | an error that `is_a?(StopSignal)` | stopped |
    | any other error | failed |

  - `run_session` feeds the parsed JSON to `usage.see`.
  - `stream_session`, `send_message_streaming` and `send_initial_streaming` feed every
    parsed event to `usage.see`. The raw-line paths parse each line with
    `JSON.parse rescue nil`.
  - On `:tick` or a keepalive, call `AiRun::Recorder.progress!`.
  - `stop_child(pid, io: nil, usage: nil)` sends INT, then keeps reading `io` for up to
    `INT_GRACE_SECONDS`, feeding events to `usage` (for json mode it buffers the text and
    parses it at the end). Then it sends TERM, waits `KILL_GRACE_SECONDS`, and KILLs.
  - `popen_streaming`: when the caller's block raises
    `IOError`/`Errno::EPIPE`/`ActionController::Live::ClientDisconnected`, it stops
    calling the block, keeps reading to EOF (feeding usage), then re-raises the first
    error.
  - Leave `Designs::SetupRunJob`'s `pkill -TERM` as it is. That process's job is dead, so
    nobody reads the INT result, and the sweeper covers the row (a deviation from spec §2
    with the same outcome).
- [ ] **Step 4:** Run `claude_cli_service_recording_test.rb`,
  `claude_cli_service_test.rb` and `claude_cli_service_mcp_test.rb`.
  Expected: PASS, 59 old runs included.
- [ ] **Step 5: Commit.** Message: `feat: every Claude run is recorded, and stops and timeouts interrupt the CLI so it reports its cost`.

---

### Task 4: Chats and handoff pass their attribution

**Files:**
- Modify: `app/controllers/concerns/chat_streaming.rb` (both `ClaudeCliService.new` calls)
- Modify: `app/services/task_handoff.rb` (`TaskHandoff.new(task, user:)`, and the call in
  `bring_over_handoff` passes `current_user`)
- Modify: `test/test_helpers/fake_chat_cli_test_helper.rb` (fakes accept the keyword; no
  change needed if `**keywords`)
- Test: `test/controllers/chat_sessions_controller_test.rb`,
  `test/controllers/brief_chat_sessions_controller_test.rb`,
  `test/controllers/breakdown_chat_sessions_controller_test.rb`,
  `test/services/task_handoff_test.rb`

**Interfaces:**
- Consumes: `AiRun::Attribution.for_task_chat` and `for_handoff` (Task 2).

- [ ] **Step 1: Write the failing tests.**

```ruby
test "a Briefing chat is attributed to the task's conversations and the person" do
  with_fake_cli do |captured|
    post jira_task_brief_chat_session_path(@task)
    a = captured[:attribution]
    assert_equal "task_conversations", a.area; assert_equal @task, a.item; assert_equal users(:one), a.started_by
  end
end
test "a follow-up on the ticket chat is attributed to Chat with AI on a ticket" # task not in pipeline, refine, with_message_cli built.last[:attribution].area == "ticket_chat"
test "the breakdown chat counts as an AI estimate"
test "a handoff is attributed to the new task and the person who opened its chat" # TaskHandoff test: captured attribution label ends with "· Handoff"
```

- [ ] **Step 2:** Run the four files.
  Expected: FAIL. `captured[:attribution]` is nil until the code passes it; once Task 3 is
  in, a missing attribution raises `ArgumentError` in the real `new`.
- [ ] **Step 3: Implement.** `chat_streaming.rb` builds the attribution with
  `AiRun::Attribution.for_task_chat(@task, purpose: chat_purpose, user: current_user)`.
- [ ] **Step 4:** Run the four files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: task chats and handoffs say whose AI run it is`.

---

### Task 5: Background jobs pass their attribution and who started them

**Files:**
- Modify:
  - `app/jobs/pr_review_job.rb`
  - `app/jobs/auto_estimate_job.rb`: `perform(task_id, force: false, started_by_id: nil)`
  - `app/jobs/backfill_delivered_estimates_job.rb`
  - `app/jobs/alert_rule_run_job.rb`: `perform(alert_rule_id, started_by_id: nil)`. The
    `limits_concurrency` key becomes `->(alert_rule_id, **) { alert_rule_id }`.
  - `app/jobs/bug_attribution_job.rb`: `perform(project_id, jira_key, started_by_id: nil)`.
    The `BugAttribution` is saved (status `pending`) before Claude runs, so it has an id.
  - `app/jobs/project_features_scan_job.rb`: `perform(project_id = nil, started_by_id: nil)`
- Enqueue sites that pass `started_by_id: current_user.id`:
  - `app/controllers/workshop/alert_rules_controller.rb:73`
  - `app/controllers/workshop/ideas_controller.rb:260`
  - `app/controllers/brief_commits_controller.rb:20`
  - `app/controllers/workshop/bugs_controller.rb:31`
  - `app/controllers/workshop/configuration_controller.rb:102`
- Test: the matching `test/jobs/*_test.rb` and controller tests

**Interfaces:**
- Consumes: Task 2 factories. Each job builds its service with
  `attribution: AiRun::Attribution.for_…(record, user: User.find_by(id: started_by_id))`.

- [ ] **Step 1: Write the failing tests.** There is one per job, and each asserts the
  captured `attribution` (the area, the item, and `automation` or `started_by`) from the
  existing fake-service stubs in those tests:
  - `"a PR review run is the PR review automation's"`: `automation == "PR review"`,
    `item == review`.
  - `"an estimate from the Estimate button names the person"`: `started_by == users(:one)`.
  - `"a scheduled estimate names the automation"`: `automation == "AI estimate"`.
  - `"Run now names the person; the schedule names the rule"`.
  - `"a bug analysis has a saved item before Claude runs"`: `a.item.persisted?`.
  - `"a feature scan Refresh names the person"`.
  - `"backfill names the backfill automation"`.
  - `"Run now enqueues with the person"`:
    `assert_enqueued_with(job: AlertRuleRunJob, args: [rule.id, { started_by_id: users(:one).id }])`.
  - The same enqueue check for the Estimate, Analyze and Refresh controller actions.
- [ ] **Step 2:** Run the affected job and controller test files.
  Expected: FAIL.
- [ ] **Step 3:** Implement the signatures above.
- [ ] **Step 4:** Run the same files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: automation runs name the automation, and runs a person started name the person`.

---

### Task 6: Designs turns and the describe turn pass their attribution

**Files:**
- Modify: `app/jobs/designs/turn_job.rb`:
  - pass `attribution: AiRun::Attribution.for_design_turn(turn)` to `claude_factory.call`;
  - `class Stopped < Failure; include ClaudeCliService::StopSignal; end`.
- Modify: `app/jobs/designs/describe_job.rb`:
  - pass `attribution: AiRun::Attribution.for_describe(turn, user: turn.chat_message.user)`;
  - `Stopped` includes `ClaudeCliService::StopSignal`.
- Test: `test/jobs/designs/turn_job_test.rb`, `test/jobs/designs/describe_job_test.rb`,
  `test/jobs/designs/setup_run_job_test.rb`

- [ ] **Step 1: Write the failing tests.**
  - `"a thread turn is attributed to its thread and requester"`: the options
    `fake_claude(during:)` captured have `attribution.item == thread` and `area ==
    "designs"`.
  - `"an import's setup turn is attributed to the import and whoever started it"`.
  - `"the describe turn is attributed to the thread and the person who accepted"`.
  - `"a stopped turn's error is a stop signal"`:
    `assert Designs::TurnJob::Stopped.include?(ClaudeCliService::StopSignal)`.
- [ ] **Step 2:** Run the three files.
  Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the three files.
  Expected: PASS. Also run `grep -rn "ClaudeCliService.new\|claude_factory.call" app lib`
  and confirm every hit passes `attribution:`.
- [ ] **Step 5: Commit.** Message: `feat: Designs turns, imports and descriptions record their AI runs`.

---

### Task 7: Read side: `AiCosts` and `AiCostFormatter`

**Files:**
- Create: `app/models/ai_costs.rb`, `app/helpers/ai_costs_helper.rb`,
  `app/models/ai_cost_formatter.rb`
- Test: `test/models/ai_costs_test.rb`, `test/models/ai_cost_formatter_test.rb`,
  `test/helpers/ai_costs_helper_test.rb`

**Interfaces:**
- Produces:
  - `AiCosts.new(workspace)`.
  - `#item_figures(items, area:) -> Hash{[type, id] => AiCosts::Figure}`. It runs one
    grouped query over finished runs, own key included, priced or not.
  - `AiCosts::Figure = Data.define(:total, :this_month, :priced_runs, :runs)`, where
    `total` and `this_month` are BigDecimal sums of `price_usd`.
  - `#area_months(area, limit: 12) -> [AiCosts::Month(month: Date, amount:, runs:)]`.
    Billable runs only, newest first, always starting with the current month.
  - `#month(month) -> AiCosts::Summary`.
  - `#all_time -> AiCosts::Summary`.
  - `AiCosts::Summary` fields:
    - `total`, `runs`, `unknown_runs`, `own_key_total`;
    - `own_key_projects: [[name, runs, amount]]`;
    - `by_area: [[area, runs, amount]]` (all 8, in `AREAS` order);
    - `by_project: [[name, runs, amount]]` (by amount, descending);
    - `months: [[Date, amount, limit]]` (all time only);
    - `limit: AiMonthLimit or nil`;
    - `first_run_at`.
  - `#runs(month, offset: 0, limit: 50) -> ActiveRecord::Relation`: finished runs,
    newest first, `includes(:started_by, :project)`.
  - `AiCostFormatter.money(amount) -> "$1,234.56"`.
  - `AiCostFormatter.item(figure) -> String or nil`. It returns nil when there are no runs.
  - `AiCostFormatter.tokens(run) -> "184k in · 12.4k out · 96k cache"`.
  - `AiCostsHelper#ai_costs_visible? -> Boolean`.
  - `AiCostsHelper#ai_item_cost(figures, record) -> String or nil`. It returns nil when not
    visible.

- [ ] **Step 1: Write the failing tests.**

```ruby
# ai_cost_formatter_test.rb
test "item figure: one amount when the month is all of it" do
  assert_equal "$0.68", AiCostFormatter.item(fig(total: "0.68", month: "0.68"))
  assert_equal "$12.40 ($3.23 this month)", AiCostFormatter.item(fig(total: "12.40", month: "3.23"))
  assert_equal "$0.74 (none this month)", AiCostFormatter.item(fig(total: "0.74", month: "0"))
  assert_equal "unknown", AiCostFormatter.item(fig(total: "0", month: "0", priced_runs: 0, runs: 2))
end
test "money groups thousands" do
  assert_equal "$1,446.15", AiCostFormatter.money(BigDecimal("1446.149"))
end
test "tokens read like the designs" do
  # 184_000/12_400/96_000 → "184k in · 12.4k out · 96k cache"; 2_100_000 → "2.1M"; 400 → "0.4k"; 0 → "0"
end
```

```ruby
# ai_costs_test.rb
test "areas and projects add up to the total, own key apart"
test "mixed project splits own key from totals" # project with one own-key designs run and one billable chat run: by_project has the billable part, own_key_projects the other, total excludes own key
test "deleted item stays in totals" # run with item_type "PrReview" id 0 still in month(...).by_area pr_reviews
test "unknown cost is counted apart and never as zero" # total ignores nil-price run; unknown_runs == 1
test "item_figures sums only the asked area for each item" # task with a task_conversations run and an estimates run
test "area_months starts with this month even with no runs"
test "all_time months carry each month's frozen limit"
```

```ruby
# ai_costs_helper_test.rb
test "costs show only when the organization allows and the person asked" # 4 combinations
```

- [ ] **Step 2:** Run the three files.
  Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Month ranges are `month.in_time_zone.all_month`.
  - Sum with `sum(:price_usd)`, which skips NULL.
  - "unknown" in the formatter means `priced_runs == 0 && runs > 0`.
  - Token rule: `k = (n / 1000.0).round(1)`; when `k >= 100`, `k = k.round`; strip a
    trailing `.0`. Millions are `(n / 1e6).round(1)` with `M`. Zero is `"0"`.
- [ ] **Step 4:** Run the three files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: AI cost sums and formatting`.

---

### Task 8: Personal and organization switches

**Files:**
- Modify: `app/controllers/profiles_controller.rb` (permit `:show_ai_costs`),
  `app/views/profiles/show.html.erb`
- Create: `app/views/profiles/_ai_costs_card.html.erb`. Port `ai-costs-card` and
  `profile.html` / `profile-costs-off.html`: the toggle in its own form, auto-submitting
  `PATCH profile` with `user[show_ai_costs]`, and the three format examples in $.
- Modify: `app/views/workshop/configuration/_ai_tab.html.erb`. Add the "AI costs in the
  product" Shown / Hidden-for-everyone control (`configuration.html`,
  `configuration-costs-off.html`) and the own-key paragraph worded as in spec §5.
- Modify: `config/routes.rb` (`patch "configuration/ai_costs", to:
  "configuration#update_ai_costs", as: :configuration_ai_costs` inside `namespace
  :workshop`) and `app/controllers/workshop/configuration_controller.rb`
  (`update_ai_costs`: `workspace_admin?` or 404; sets `current_workspace.ai_costs_enabled`;
  redirects to the AI tab with the notice "AI costs are now hidden for everyone in
  #{name}" / "AI costs are now shown in #{name}")
- Test: `test/controllers/profiles_controller_test.rb`,
  `test/controllers/workshop/configuration_controller_test.rb`

- [ ] **Step 1: Write the failing tests.**
  - `"a person turns AI costs on"`: PATCH → `users(:one).reload.show_ai_costs?`.
  - `"the profile card says Unavailable while the organization hides costs"`.
  - `"an organization admin hides costs for everyone"`.
  - `"a non-admin cannot flip the organization switch"`: 404, unchanged.
  - `"the AI tab explains own key per run"`:
    `assert_includes body, "Other AI features run on Flosis and count as usual"`.
- [ ] **Step 2:** Run the two files.
  Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the two files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: personal and organization switches for AI cost display`.

---

### Task 9: Item figures on working screens

**Files:**
- Modify the controllers that load each list so they set
  `@ai_costs = AiCosts.new(current_workspace).item_figures(records, area: …)`:
  - `Workshop::ProcessController` (pr: `@pr_reviews`; estimate: the estimate tab's tasks)
  - `Workshop::BugsController` (the bug rows' `BugAttribution`s)
  - `Workshop::IdeasController#show` (`[@idea]`, task_conversations)
  - the Designs module controller(s) for the thread panel (`[thread]`) and the imports list
    / built import (`DesignSetup`s)
- Modify these views. Each figure is ported from its design and uses `ai_item_cost`:
  - `app/views/workshop/ideas/_chat_panel.html.erb`: a second line under the persona chip,
    with the wallet icon
  - `app/views/workshop/ideas/_ready.html.erb`: under the task title
  - `app/views/workshop/process/_pr_tab.html.erb`: `· $x` at the end of the meta line
  - `app/views/workshop/process/_estimate_tab.html.erb`: on the estimate row
  - `app/views/workshop/bugs/_bug_list.html.erb`: on the bug row, failed rows included
  - `app/views/workshop/designs_module/_thread_panel.html.erb`: after the branch standing
    in the state line
  - `app/views/workshop/designs_module/_imports.html.erb` and
    `app/views/workshop/design_imports/_built.html.erb`: after the contexts
- Test: `test/controllers/workshop/process_controller_test.rb`, `…/bugs_controller_test.rb`,
  `…/ideas_controller_test.rb`, `…/designs_module_controller_test.rb` (or whichever file
  tests those pages today)

- [ ] **Step 1: Write the failing tests.** For each page there are two tests:
  - `"<page> shows the item's AI cost when costs are on"`: with costs on (both switches),
    an `AiRun` priced 12.40 total / 3.23 this month for the item, the body includes
    `"$12.40 ($3.23 this month)"`.
  - `"<page> shows no AI cost when the person has not turned costs on"`: no `"$"` figure.
- [ ] **Step 2:** Run the affected files.
  Expected: FAIL.
- [ ] **Step 3: Implement.** Use one `item_figures` call per page, never one per row.
- [ ] **Step 4:** Run the affected files.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: task conversations, PR reviews, estimates, threads, imports and bug analyses show what they cost`.

---

### Task 10: Area figures on area pages

**Files:**
- Create: `app/views/workshop/shared/_area_cost.html.erb`
  - locals: `area:`, `months:` (`AiCosts::Month` list)
  - ports `components/area-cost`: a faint label, a select of months whose value is
    `"amount|runs"`, and the amount and runs spans
- Create: `app/javascript/controllers/area_cost_controller.js`. On select change it splits
  the value and sets the amount (`$` + amount) and the runs targets.
- Modify these title rows to put the partial at the right end, in a
  `flex flex-wrap items-baseline justify-between` row with the `<h1>`:
  - `app/views/workshop/pipeline/index.html.erb` (task_conversations, beside Setup)
  - `app/views/workshop/process/show.html.erb` (area by `@tab`: pr → pr_reviews,
    estimate → estimates, alerts → agents)
  - `app/views/workshop/bugs/show.html.erb` (bug_analysis)
- Modify: `app/views/workshop/designs_module/_imports.html.erb`. The heading row gets the
  current month only: `"Designs and imports · November 2026 · $182.35 · 96 runs"`.
- Test: the controller tests of those four pages

- [ ] **Step 1: Write the failing tests.**
  - `"the PR tab shows the organization's PR reviews this month"`: the body includes the
    sum of billable `pr_reviews` runs this month across two projects.
  - `"the area figure leaves out own key runs"`.
  - `"no area figure while costs are off"`.
  - `"the month picker lists last month when it had runs"`: an `option` with
    `"October 2026"`.
- [ ] **Step 2:** Run.
  Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run.
  Expected: PASS. Then run `bin/rails tailwindcss:build`.
- [ ] **Step 5: Commit.** Message: `feat: each AI area shows what it cost the organization in a chosen month`.

---

### Task 11: Consumption

**Files:**
- Modify: `config/routes.rb` (`get "consumption", to: "consumption#show", as:
  :consumption` inside `namespace :workshop`)
- Create: `app/controllers/workshop/consumption_controller.rb`
  - `< Workshop::BaseController`
  - `skip_before_action :require_current_project!, :require_project_member!`
  - 404 unless `workspace_admin?`
  - params: `month=YYYY-MM` (default: this month) and `view=all`
  - runs paginated by `offset`, 50 at a time, in a Turbo frame `consumption_runs`
- Create:
  - `app/views/workshop/consumption/show.html.erb`
  - `_period.html.erb`
  - `_plan_card.html.erb` (limit bar, "% of the limit · $x left" / "over by $x", plan name
    + price + "assigned <date>", "NO PLAN")
  - `_notes.html.erb` (charged / own key / unknown)
  - `_table.html.erb` (by area, by project + own-key rows below the total)
  - `_runs.html.erb`
  - `_all_time.html.erb` (by month against each month's limit)
  - All of these port `designs/admin/consumption*.html` and `components/consumption-*`,
    with € replaced by $.
- Modify: `app/views/layouts/_clar_sidebar.html.erb`. A Consumption item goes in the ADMIN
  group, shown when `workspace_admin?`, with the wallet icon from the design. The ADMIN
  label shows when it does.
- Test: `test/controllers/workshop/consumption_controller_test.rb`

- [ ] **Step 1: Write the failing tests.**

```ruby
test "only organization administrators reach Consumption" # employee → 404; admin → 200
test "the sidebar offers Consumption to administrators only"
test "a month shows areas and projects that add up to the total" # assert_select the Total rows equal
test "over the limit says by how much and that nothing was blocked" # month total 1446.15, limit 1200 → "over by $246.15"
test "no plan says so and still shows prices"
test "unknown runs are counted, not priced as $0" # "2 runs came back with no cost"
test "run list marks a deleted item, a stopped run, own key and the automation"
test "all time lists each month against its own limit"
test "cost and margin never appear" # refute_includes body, "margin"; refute cost_usd value
test "show 50 more loads the next page" # 51 runs → frame with offset=50 has 1 row
```

- [ ] **Step 2:** Run.
  Expected: FAIL.
- [ ] **Step 3:** Implement. Ignore both cost switches here.
- [ ] **Step 4:** Run.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Consumption shows an organization's AI spend against its plan`.

---

### Task 12: `/hidmin` shell rework

**Files:**
- Modify: `app/views/layouts/hidmin.html.erb`. Port `components/flosis-admin-shell`:
  - the mark and the FLOSIS ADMIN badge in AI violet;
  - the theme toggle and the account chip ("Flosis staff");
  - a left sidebar with **BILLING** (Plans, Models & prices, Organizations) and
    **STAFF** (Overview, People);
  - the main area keeps the flash.
  - Reuse the `clar-sidebar` / `clar-nav-item` classes.
- Modify: `config/routes.rb` (hidmin):
  - `resources :plans, only: %i[index new create edit update]`
  - `resources :models, only: %i[index update], controller: "ai_models" do collection { post :read } end`
  - `member { patch :assign_plan }` on workspaces
  - `resources :ai_runs, only: [] do member { patch :looked_at } end`
- Test: `test/controllers/hidmin/access_test.rb`. It extends the existing coverage so every
  new route is 404 for a non-staff user.

- [ ] **Step 1: Write the failing tests.**
  - `"the staff sidebar lists billing and staff pages"`: `assert_select` links to plans,
    models, organizations, overview and people.
  - `"every billing page is hidden from non-staff"`: 404s for the new paths.
- [ ] **Step 2:** Run `test/controllers/hidmin/access_test.rb`.
  Expected: FAIL.
- [ ] **Step 3:** Implement the layout and routes. Add empty controllers for the new routes
  (Tasks 13–15 fill them in).
- [ ] **Step 4:** Run all of `test/controllers/hidmin/`.
  Expected: PASS, the existing tests included.
- [ ] **Step 5: Commit.** Message: `feat: hidmin becomes the Flosis admin shell with billing and staff groups`.

---

### Task 13: Plans

**Files:**
- Create: `app/controllers/hidmin/plans_controller.rb`,
  `app/views/hidmin/plans/index.html.erb`, `_form.html.erb`, `new.html.erb`,
  `edit.html.erb`. These port `plans.html` and `plan-new.html`:
  - the live "A run that costs $10.00 is charged $13.00" line comes from a small Stimulus
    controller, `plan_margin_controller.js`;
  - the models table shows each `AiModel`'s four prices, with BY HAND on hand-set prices
    and DEFAULT on the model of the newest recorded run;
  - "Assign it now" offers an organization select, optional.
- Modify: `app/models/ai_plan.rb` (`after_update_commit` → `AiMonthLimit.refresh_current!`
  for each of its workspaces when the name or `monthly_price_usd` changed)
- Test: `test/controllers/hidmin/plans_controller_test.rb`

- [ ] **Step 1: Write the failing tests.**
  - `"staff create a plan with models and assign it"`: POST name "Scale", monthly 1200,
    margin 30, two model ids, and an organization. Then the `AiPlan` has 2 models and
    `workspace.ai_plan` is the plan, with `ai_plan_assigned_at` set and this month's
    `AiMonthLimit` at 1200.
  - `"the plans list shows price, margin, models and organizations"`.
  - `"a plan needs a name, a price and a margin"`: 422.
  - `"editing a plan leaves last month's limit"`: last month's row is 1200; update the
    price to 1500; last month is still 1200 and this month is 1500.
- [ ] **Step 2:** Run.
  Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Flosis staff create plans with a price, a margin and models`.

---

### Task 14: Models & prices and the daily read

**Files:**
- Create: `app/services/ai_price_read.rb`, which does
  `AiPriceRead.new(fetch: ->(url) { Net::HTTP.get(URI(url)) }).call -> {updated:, failed:}`.
  - `URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"`.
  - It calls `AiModel.seed!` first.
  - For each `AiModel` it looks up the entry in this order, keeping only entries whose
    `litellm_provider == "anthropic"`:
    1. key `model_id`;
    2. key `"anthropic/#{model_id}"`;
    3. the newest key starting with `"#{model_id}-"`.
  - Prices: `input_cost_per_token`, `output_cost_per_token`,
    `cache_creation_input_token_cost` and `cache_read_input_token_cost`, each × 1_000_000.
  - A success sets `price_source: "read"` and `read_at`.
  - A missing or failed model gets `read_failed_at`, and its prices are kept.
  - A failed fetch marks every model failed and raises nothing.
- Create: `app/jobs/ai_price_read_job.rb`. Add it to `config/recurring.yml` (production:
  `ai_price_read`, `"0 6 * * *"`).
- Create: `app/controllers/hidmin/ai_models_controller.rb`:
  - `index`;
  - `update`: one price field; sets `price_source: "hand"` and `hand_set_at`; responds 204
    for the blur-save;
  - `read`: runs `AiPriceRead` now and redirects with "N of M prices updated".
- Create: `app/views/hidmin/ai_models/index.html.erb`, porting `models.html` (the status
  line, Read now, the by-hand/failed alert, the table with IN USE / BY HAND / failed date).
- Create: `app/javascript/controllers/price_field_controller.js`. On blur, if the value
  changed, it PATCHes.
- Test: `test/services/ai_price_read_test.rb`,
  `test/controllers/hidmin/ai_models_controller_test.rb`

- [ ] **Step 1: Write the failing tests.**
  - `"reads per-1M prices for known models"`: the fixture JSON
    `{"claude-opus-5-5":{"litellm_provider":"anthropic","input_cost_per_token":1.5e-05,...}}`
    gives `input_usd_per_mtok == 15`.
  - `"a dated key is found for an undated id"`.
  - `"a model the source lacks keeps its price and is marked failed"`.
  - `"a failed fetch changes no price"`.
  - `"a typed price is marked by hand until the next successful read"`.
  - `"Read now reports how many prices were updated"`.
- [ ] **Step 2:** Run.
  Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Models & prices read daily, with prices typed by hand when a read fails`.

---

### Task 15: Organizations billing, organization detail, assigning a plan, looked at

**Files:**
- Modify: `app/controllers/hidmin/workspaces_controller.rb` and
  `app/views/hidmin/workspaces/index.html.erb`. The index becomes the billing table from
  `organizations.html`:
  - columns: organization link with "N projects · M on its own key", plan (or an inline
    plan select + Assign for an organization with no plan), margin, cost, price, a bar
    against the limit, runs and an UNKNOWN count (not yet looked at);
  - the three notes below it;
  - "New organization" stays.
  - It uses one `AiCosts` per workspace for this month, or a single grouped query across
    workspaces (the builder's choice), with no N+1 per row beyond that.
- Modify: `app/views/hidmin/workspaces/show.html.erb`. Add the billing part from
  `organization.html` on top:
  - cost, price and margin kept (with each margin in use this month);
  - the limit bar;
  - by area and by project, cost → price;
  - own key "billed to them";
  - unknown runs, listed with a "Looked at" button each;
  - runs with model, cost, margin and price.
  - The existing People / Settings / Projects sections follow unchanged.
- `assign_plan`: sets `ai_plan_id` and `ai_plan_assigned_at`, calls
  `AiMonthLimit.refresh_current!`, and redirects with "Plan assigned".
- Create: `app/controllers/hidmin/ai_runs_controller.rb#looked_at`. It sets
  `unknown_reviewed_at` and `unknown_reviewed_by` and redirects back.
- Test: `test/controllers/hidmin/workspaces_controller_test.rb`,
  `test/controllers/hidmin/ai_runs_controller_test.rb`

- [ ] **Step 1: Write the failing tests.**
  - `"organizations list shows cost, price and the margin"`.
  - `"assigning a plan sets this month's limit"`.
  - `"an organization's page splits cost and price by area and project"`.
  - `"own-key usage is billed to them and outside the total"`.
  - `"looked at clears the unknown flag on the list"`: the UNKNOWN count goes from 2 to 1.
  - `"existing organization settings are still on the page"`.
- [ ] **Step 2:** Run.
  Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run.
  Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat: Flosis staff see each organization's AI cost, price and margin, and assign plans`.

---

### Task 16: Whole-branch verification

**Files:** none new, apart from screenshots in `/Users/kacper/gold/.playwright-mcp/` (git-ignored)

- [ ] **Step 1: Run the full suite.** Run
  `PARALLEL_WORKERS=1 DATABASE_URL=postgres://localhost/gold_test_scrum70 bin/rails test`.
  Expected: only the known date-dependent failures. Fix anything else.
- [ ] **Step 2: Check no call site was missed.** Run
  `grep -rn "ClaudeCliService.new\|claude_factory.call" app lib`.
  Expected: every hit passes `attribution:`.
- [ ] **Step 3: Compare with the designs in the browser.** Use the harness from memory
  `reference_browser_check_without_dev_server` (dump the page HTML from a throwaway test,
  serve it through Playwright `page.route`). Check side by side:
  - Consumption (month, over limit, no plan, all time);
  - the PR tab with the area figure and the row figures;
  - the chat panel figure;
  - profile on and off;
  - hidmin Plans, New plan, Models, Organizations and Organization.
  Note any visible drift and fix it.
- [ ] **Step 4: Spec deviations.** Append a "Deviations" note to the spec for anything
  built differently, e.g. the SetupRunJob pkill left on TERM. Commit it.
- [ ] **Step 5: Drop the private DB.** Run
  `RAILS_ENV=test DATABASE_URL=postgres://localhost/gold_test_scrum70 bin/rails db:drop`.
