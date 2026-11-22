# AI usage and cost per organization (SCRUM-70)

Task: `tasks/SCRUM-70/scrum-70.md` (description v5). Accepted designs:
`RubyOnSaas-wiki/flosis-app-design` at `ed2d5e9` (the screens listed in the task file).
Branch: `feat/scrum-70-add-token-calculations`.

## Why

Flosis runs Claude in many places: task conversations, PR reviews, estimates, agents,
Designs and bug analysis. None of those runs is saved, so nobody can say what an
organization, a project or a single run cost. Flosis is moving to billing by token usage.
This ticket records and prices every AI run and shows organizations what they spent.
Invoicing and payments are the next ticket.

## Goals

- Every Claude run leaves a usage record. That includes runs that fail, time out or are
  stopped.
- Each record says which organization, project, area and item it belongs to. It also says
  who started it: a person, or the automation's name.
- Two amounts per run:
  - **cost**: what Claude reported. Flosis staff only.
  - **price**: cost plus the plan's margin, frozen at the day of the run. Organizations see
    this, and it is what counts toward the limit.
- Plans (name, monthly price = limit, margin, included models), Models & prices, and an
  Organizations billing view, all in `/hidmin`. `/hidmin` is reworked to the designed
  Flosis-admin shell.
- Consumption page for organization administrators.
- Small cost figures on items and areas. They are hidden by default, each person opts in,
  and an organization switch can turn them off for everyone.

## Non-goals

Taken from the ticket, plus decisions made in the conversation:
- Invoicing and payments.
- Blocking at the limit.
- Letting users choose a model.
- Pricing runs from before this ships.
- A plan changed mid-month (the billing ticket).
- Plans' model lists restrict nothing for now; they are information.

## Anti-goals (a failure even if it works)

- A run that slips through unrecorded. An AI call site added later must not be able to skip
  recording by accident.
- A recording error that breaks or slows an AI run. Recording must never raise into the run.
- Counting a run with no reported cost as 0.
- Recomputing past figures. A margin or plan change, or a deleted item, must never move a
  closed month.
- Cost or margin leaking to anyone outside Flosis staff.
- Cost figures that compete with the working screens. They are light and muted, take no new
  lines or cards, and have no links to Consumption.

## Decisions made with Kacper (2026-11-22)

1. **All money is in US dollars**: cost, price, plan price, limit and the model price list.
   The designs show euro; every `€` becomes `$`. No currency conversion anywhere.
2. **Recording approach (A)**: recording lives inside `ClaudeCliService` (see Approaches).
3. **`/hidmin` is reworked to the new Flosis-admin designs**:
   `designs/flosis-admin/*.html` and `components/flosis-admin-shell`.
4. **Own key is judged per run.** A run is own key only when it actually ran on the
   client's key, which today means Designs only.
   - A keyed project's chats, PR reviews, estimates, agents, bug analysis and feature scan
     run on Flosis's login. Flosis pays for them, so they are priced and count toward the
     limit.
   - Moving every AI feature onto a project's key may come later. Per-run recording already
     handles it, because the flag follows the key each run used.

## Constraints

- **Every one of the 13 call sites goes through `ClaudeCliService`.** The map is in "Call
  sites" below.
- **What the CLI's result carries.** Checked with CLI 2.1.330:
  - `total_cost_usd`.
  - `usage`: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
    `cache_read_input_tokens`.
  - `modelUsage`, keyed by model id, each entry with tokens and `costUSD`.
  - `"costBasis": "list"`, meaning the cost is the CLI's list-price figure. That figure is
    "what the provider reports".
- **How the CLI reacts to signals** (tested locally):
  - SIGTERM: it dies with no result line, so the cost is lost.
  - SIGINT: it prints a result (`subtype: error_during_execution`) that includes
    `total_cost_usd`.
  - So stops and timeouts must send INT first, wait a short grace period while reading what
    the CLI prints, then TERM, then KILL.
- **Streamed `assistant` events carry `message.usage`.** This lets a run that never produces
  a result keep its input and cache tokens. Output tokens there are partial.
- **Only Designs passes a project's own key today.**
  - Designs uses `ProjectCredentials#designs_api_key`.
  - Setup turns may also use Flosis's `FLOSIS_DESIGNS_SETUP_API_KEY`, which is NOT the
    client's key.
  - Every other call site runs on the server's CLI login.
- **Jobs never receive the person who triggered them.** User-triggered jobs (Run now,
  Estimate, Analyze, Refresh) need a new `started_by_id` argument.
- **Details Gathering and the Jira Tasks ticket chat share `ChatSession` purpose `refine`
  and the same controller.** The area is told apart by `task.in_pipeline?`.
- **Time zone.** The app runs in Warsaw (`config.time_zone`), and calendar months are Warsaw
  months.
- **Who is who.**
  - An organization is a `Workspace`.
  - An organization administrator is `WorkspaceMembership#workspace_admin`.
  - Flosis staff is `users.flosis_staff`, gated by `FlosisStaffOnly`.
- **Tests.** Minitest. The suite runs with `PARALLEL_WORKERS=1` locally (pg segfault). Some
  tests fail by date on production itself (reports_controller, holiday_request,
  workshop_report); they are not regressions.

## Approaches

- **(A) Record inside `ClaudeCliService` — chosen.**
  - Every call site passes an attribution: workspace, project, area, item, item label, and
    who started the run.
  - The service reads tokens and cost from the CLI's output and writes one `AiRun` in an
    `ensure`, so failures, timeouts and stops are covered.
  - The attribution is a required argument, so a new call site cannot forget it.
  - Cost of the approach: all 13 call sites change, and the service's stop path changes.
- **(B) Each call site records after its run.** Everything is explicit, but it means 13
  sites times their failure paths, and an exception loses the data. Rejected: it is easy to
  miss, which is anti-goal 1.
- **(C) Read the CLI transcripts on the server periodically.** Rejected for three reasons:
  - most runs keep no session id to attribute by;
  - transcripts carry no cost, so the cost would come from the price list, which the ticket
    forbids;
  - it depends on files the CLI may delete.

## The design

### 1. Data

**`ai_runs`**: one row per Claude CLI process.

| column | notes |
|---|---|
| `workspace_id` | FK, not null. `Workspace has_many :ai_runs, dependent: :delete_all` |
| `project_id` | FK, nullable. `Project has_many :ai_runs, dependent: :nullify`, so a deleted project's runs stay in the organization total |
| `project_name` | snapshot, for a deleted project |
| `area` | string, one of `AiRun::AREAS` (below) |
| `item_type`, `item_id` | polymorphic, **no FK**, so a deleted item leaves its runs |
| `item_label` | snapshot shown in run lists: "SCRUM-70 · Briefing", "#19 Designs: say how many…", "Thread · Compact alert rules list", "Import · Designs from the app, 12 Nov", "Rule · Daily PR digest", "Nightly scan · RubyOnSaas-wiki/clar" |
| `started_by_id` | FK users, nullable, `on_delete: :nullify` |
| `automation` | string, nullable: "PR review", "AI estimate", "Bug analysis", "Feature scan", or the alert rule's name. Exactly one of `started_by_id` and `automation` is set |
| `status` | `running`, `succeeded`, `failed`, `stopped`, `timed_out`. A row is created as `running` when the CLI starts and finished when it ends (see §2) |
| `unknown_reviewed_at`, `unknown_reviewed_by_id` | when Flosis staff marked an unknown-cost run as looked at (hidmin only) |
| `model` | the model with the largest `costUSD` in `modelUsage`, or the one named by the stream |
| `model_usage` | jsonb: the CLI's `modelUsage`, kept as reported |
| `input_tokens`, `output_tokens`, `cache_write_tokens`, `cache_read_tokens` | bigint, default 0 |
| `cost_usd` | decimal(14,6), **nullable**: nil means unknown |
| `margin_percent` | decimal(6,2), nullable: the organization's margin on the day the run happened (plan or default); nil for own key |
| `price_usd` | decimal(14,6), nullable: `cost × (1 + margin/100)`, written once and never recomputed; nil when the cost is unknown; for own key it equals the cost |
| `own_key` | boolean: the run used the project's own `anthropic_api_key` |
| `claude_session_id` | string, nullable, for tracing |
| `ran_at` | datetime: when the run started. Its month is the run's month |
| `duration_ms` | integer |

Indexes:
- `[workspace_id, ran_at]`
- `[workspace_id, area, ran_at]`
- `[project_id, ran_at]`
- `[item_type, item_id]`
- `[workspace_id, cost_usd]` as a partial index where `cost_usd IS NULL`, for unknown runs

`AiRun::AREAS`, in Consumption's order and wording:
- `task_conversations`: "Task conversations"
- `designs`: "Designs and imports"
- `pr_reviews`: "PR reviews"
- `estimates`: "AI estimates"
- `agents`: "Agents and alerts"
- `bug_analysis`: "Bug analysis"
- `feature_scan`: "Project feature scan"
- `ticket_chat`: "Chat with AI on a ticket"

**`ai_plans`**:
- `name`
- `monthly_price_usd` (decimal(12,2))
- `margin_percent` (decimal(6,2))
- timestamps

**`ai_plan_models`**: a join table of `ai_plan_id` and `ai_model_id`, unique.

**`ai_models`**: the price list.
- `model_id` (unique), the CLI's id, e.g. `claude-opus-5-5`
- `name`, e.g. "Claude Opus 5.5"
- `input_usd_per_mtok`, `output_usd_per_mtok`, `cache_write_usd_per_mtok`,
  `cache_read_usd_per_mtok`
- `price_source`: `read` or `hand`
- `read_at`, the last successful read
- `read_failed_at`
- `hand_set_at`

**`ai_month_limits`**: what each month was measured against, frozen once the month closes.
It holds `workspace_id`, `month` (a date, the 1st), `ai_plan_id` (nullable), `plan_name`
and `limit_usd` (nullable when there is no plan). It is unique on `[workspace_id, month]`.
- Assigning a plan, or editing a plan's name or price, upserts the **current** month's row
  for each affected organization. Past rows are never touched.
- Consumption and hidmin read a month's limit from this table.
- The current month falls back to the live plan when no row exists yet.
- My call (builder check): without it, editing a plan would rewrite a closed month's
  "of $1,200 · over by …". A plan changed mid-month stays the billing ticket's: the
  current month simply shows the latest plan.

**`workspaces`** gets:
- `ai_plan_id` (FK, nullable)
- `ai_plan_assigned_at`
- `ai_costs_enabled` (boolean, default true): the organization switch

**`users`** gets `show_ai_costs` (boolean, default false): the personal setting.

### 2. Recording (`ClaudeCliService` + `AiRun::Recorder`)

**The attribution.**
- `ClaudeCliService.new(..., attribution:)` is a **required keyword**. Its value is an
  `AiRun::Attribution`, a small value object with `workspace`, `project`, `area`, `item`,
  `item_label`, `started_by` and `automation`.
- It is validated at construction: the area is known, and exactly one of `started_by` and
  `automation` is set.
- `ProjectCredentials`-style helpers build the common cases. Examples:
  - `AiRun::Attribution.for_task_chat(task, purpose:, user:)`
  - `.for_pr_review(review)`
- The Designs `claude_factory` lambdas in tests take the extra keyword.

**What the service reads.**
- Non-streamed runs (`--output-format json`) parse the result JSON as today and also keep
  `total_cost_usd`, `usage`, `modelUsage` and `session_id`.
- Streamed runs (`stream_session`, `send_message_streaming`, `send_initial_streaming`) watch
  the events as they go by:
  - each `assistant` event's `message.usage` is kept by message id, last value wins;
  - the `result` event gives the totals.
- A run with a result uses the result's figures. A run without one uses the summed
  `assistant` usage and gets `cost_usd: nil`.

**Status.**
- `succeeded`: a result with `is_error: false`.
- `failed`: a result with `is_error: true`, a raised `ClaudeCliError`, or any other
  exception.
- `timed_out`: `TimeoutError`.
- `stopped`: the caller's block raised a stop. Designs' `Stopped`, and a thread check that
  stands down, are told apart by the exception class that `stream_claude` re-raises; the
  service is told which classes mean "stopped".

**Stopping.**
- `stop_child` becomes: INT, then wait up to `INT_GRACE_SECONDS` (10) while still reading
  stdout so the result line is caught, then TERM and the existing grace period, then KILL.
- `run_claude` (non-streamed) does the same on timeout and parses whatever JSON came out.
- `Designs::SetupRunJob`'s `pkill` of an interrupted attempt also sends INT first. That
  process belongs to a dead job, so its run may end up unknown; that is accepted.

**Writing.**
- `AiRun::Recorder.start!` creates the row as `running` just before the CLI starts.
- `finish!` fills it in from an `ensure` around the whole run.
- Both rescue and log every error (`Rails.error.report`), so recording can never break a
  run.
- A process that dies with its job (a deploy restarting SolidQueue, a killed worker) never
  reaches the `ensure`. For those, a recurring sweeper (`AiRuns::SweepJob`, every 15
  minutes) turns rows still `running` after `STALE_AFTER` (3 h, longer than the longest
  setup turn) into `failed` with unknown cost. Their tokens are 0 unless partial usage was
  saved on the way.
- Streamed runs save the partial usage on the `running` row every 30 s, from the tick.
- My call (builder check): otherwise the runs a deploy kills would go missing, which is
  anti-goal 1.
- Lists and sums leave `running` rows out. A running row has no price yet, and it shows in
  no total until it finishes.

**Price at write time.**
- `own_key`: the margin is nil and the price equals the cost.
- Otherwise the margin is `workspace.ai_plan&.margin_percent ||
  AiRun::DEFAULT_MARGIN_PERCENT`. The default is 30, from
  `ENV["FLOSIS_DEFAULT_MARGIN_PERCENT"]`, and matches the "no plan" screens, which still
  show a price.
- The price is `cost × (1 + margin/100)`, rounded to 6 places. It is nil when the cost is
  nil.

**Own key.** `own_key` is true when the run's `api_key` equals
`project.anthropic_api_key`. Flosis's setup key and the server login are not own key.

**A new model.** A model id the price list has not seen is added to `ai_models` (no prices
yet, `price_source: read`), so the next daily read fills it in.

### 3. Call sites

| # | Where | Area | Item / label | Started by |
|---|---|---|---|---|
| A1 | `ChatStreaming#create` (brief / refine / breakdown) | brief → task_conversations; refine → task_conversations if `task.in_pipeline?`, else ticket_chat; breakdown → **estimates** (the accepted `consumption.html` says "refining a breakdown is counted under AI estimates") | Task · "KEY · Briefing" / "KEY · Details Gathering" / "KEY · Chat" / "KEY · Breakdown" | `current_user` |
| A2 | `ChatStreaming#message` | as A1, from the session's purpose and task | Task | `current_user` |
| A3 | `TaskHandoff#handed_over` | task_conversations | the new Task · "KEY · Handoff" | `current_user` of the A1 request (passed in) |
| B1 | `PrReviewJob` | pr_reviews | PrReview · "#N title" | automation "PR review" |
| B2 | `AutoEstimateJob` | estimates | Task · "KEY title" | `started_by_id` arg for the brief-commit and Estimate button; else automation "AI estimate" |
| B3 | `BackfillDeliveredEstimatesJob` | estimates | DeliveredIssue · "KEY" | automation "AI estimate backfill" |
| B4 | `AlertRuleRunJob` | agents | AlertRule · "Rule · name" | `started_by_id` arg for Run now; else automation = the rule's name |
| B5 | `BugAttributionJob` | bug_analysis | BugAttribution · "KEY title". The record is saved before the run, so it has an id | `started_by_id` arg for Analyze; else automation "Bug analysis" |
| B6 | `ProjectFeaturesScanJob` | feature_scan | Project · "Feature scan · repo" | `started_by_id` arg for Refresh; else automation "Feature scan" |
| C1 | `Designs::TurnJob` (thread turns: plan, design, check, resolve_conflicts, retry) | designs | DesignThread · "Thread · title". Each CLI process is its own run: the 60 s retry makes a second one | `turn.chat_message.user` |
| C1' | `Designs::TurnJob` for setup / import turns (via `SetupRunJob`) | designs | DesignSetup · "Import · Designs from the app, 12 Nov" | `DesignSetup.started_by` |
| C2 | `Designs::DescribeJob` | designs | DesignThread | `merge.user` |

The Designs subjects (`Designs::Subject` and its subclasses) gain an `attribution` method,
so `TurnJob` builds the service with it.

### 4. Model price list (Models & prices)

- **Source.** `AiModels::PriceRead` fetches LiteLLM's public
  `model_prices_and_context_window.json` (raw GitHub, USD per token). It reads the
  `anthropic` provider entries for every model in `ai_models` and converts them to USD per
  1M tokens.
- **When.** A recurring job runs at 06:00 Warsaw. There is also a "Read now" button.
- **A model that is missing or fails to read** keeps its last price and gets
  `read_failed_at`.
- **Typing a price by hand** sets `price_source: hand`. The price stands until the next
  successful read overwrites it and turns the source back to `read`.
- **What the list is for.** It is reference only: it shows Plans what each model costs.
  Runs are never priced from it.
- **The list shows**:
  - Anthropic models seen in runs;
  - models staff added;
  - a seed of the current family: Opus 5.5, Sonnet 5.5 and Haiku 5.5.

### 5. Organization screens

**Visibility of item and area figures.** A figure is drawn only when both of these hold:
- `workspace.ai_costs_enabled`;
- `current_user.show_ai_costs`.

The helper `ai_costs_visible?` is used everywhere. Consumption ignores both switches.

**Item figure format** (`AiCostFormatter`):

| Case | Shows |
|---|---|
| total equals this month's amount | `$0.68` |
| total differs from this month's amount | `$12.40 ($3.23 this month)` |
| nothing spent this month | `$0.74 (none this month)` |
| all runs have unknown cost | `unknown` |
| some runs have unknown cost | the known sum |

The figure is the price, and own-key runs count at their cost.

**Item figures**, each riding on a line that already exists, exactly as in the designs:
- **Task conversation:**
  - in the chat panel, a second line under the persona chip (Briefing and Details);
  - in the Ready panel, under the task title.
  - Both show the task's total: brief + refine + handoff.
- **PR review:** the end of the meta line of the PR review row (`_pr_tab`).
- **AI estimate:** the estimate row (`_estimate_tab`), showing the task's whole estimating
  history.
- **Design thread:** the thread's state line, after the branch's standing.
- **Design import:** the import's line on the imports list and the built import page.
- **Bug analysis:** the bug row (`_bug_list`). A failed analysis still shows what it spent.

**Area figures** use the `area-cost` component: muted, at the right end of the page title's
row, with a month picker listing the months that have runs plus the current month, newest
first.
- On these pages:
  - Create Tasks (task_conversations)
  - AI PR Reviews (pr_reviews)
  - AI Estimate (estimates)
  - AI Agents & Alerts (agents)
  - Bug Reporting (bug_analysis)
  - the Designs imports page (designs; current month only, in its heading, as designed)
- **The figure is organization-wide**, as in the designs: the PR tab shows the
  organization's PR reviews, and the numbers match Consumption's area rows.
- **Own-key runs are left out**, as on Consumption.

**Profile → "AI costs" card.**
- A toggle with the three format examples from the design.
- When the organization switch is off, the card shows "Unavailable" (`profile-costs-off`).

**Configuration → AI.**
- "AI costs in the product": Shown / Hidden for everyone.
- A toast confirms the change.
- Only an organization administrator can change it.
- An own-key paragraph under the Anthropic key field, reworded from the design's to match
  decision 4: "Designs runs on this key, so its runs are recorded and shown on Consumption,
  marked own key, and do not count toward the organization's monthly limit. Other AI
  features run on Flosis and count as usual."

**Consumption** (`/consumption`, a new item in the sidebar's ADMIN group, shown to
`workspace_admin` only; anyone else gets a 404):
- **Period bar:** a month picker, "By month" or "All time", and "N runs this month".
- **Plan card:**
  - used against the limit, with a progress bar, "% of the limit" and "left" or "over by";
  - the plan's name, its price per month and the date it was assigned;
  - "no plan" when there is none (`consumption-no-plan`);
  - over the limit: a banner with "over by X; nothing was blocked" (`consumption-over-limit`).
- **Three notes:**
  - what you are charged;
  - own key: the own-key amount and the projects it came from;
  - unknown cost: a count, never counted as $0.
- **By area:** all 8 areas, runs and price, and a Total row.
- **By project:** projects with runs, sorted by price, and a Total row. Below the total, the
  own-key amount per project, marked OWN KEY.
- Runs are split by `own_key`, so a project with both kinds appears in both lists. Areas,
  projects and the total sum only non-own-key priced runs, and they add up.
- **Runs:**
  - the newest 50, with "Show 50 more" (Turbo frame pagination);
  - columns: when, area, item label (marked DELETED when the item is gone, STOPPED or FAILED
    by status, OWN KEY), started by (person name, or AUTOMATION + its name), tokens
    (`184k in · 12.4k out · 96k cache`, where cache = read + write), and price or
    `unknown`.
- **All time** (`consumption-all-time`):
  - a total since the first run;
  - a "By month" list against each month's limit;
  - By area and By project for all time;
  - no runs list.
- **Never shown on Consumption:** cost and margin.

### 6. `/hidmin` rework (Flosis admin)

**The shell.**
- The layout becomes the designed `flosis-admin-shell`:
  - the mark and the FLOSIS ADMIN badge in AI violet;
  - the theme toggle and the account chip;
  - a left sidebar.
- The sidebar has a **BILLING** group: Plans, Models & prices, Organizations.
- My call: the existing staff pages stay, in a second group, **STAFF**: Overview and People.
  - The designs say "three pages, no more", on the assumption that staff need nothing else.
  - But organization products, memberships and "New organization" exist only in `/hidmin`
    today, and removing them is not asked for.

**Pages.**
- **Plans:** a list (plan, monthly price, margin, models, organizations) and the two
  explanatory notes. "New plan" and Edit both use the `plan-new` form, which has:
  - name, monthly price and margin, with the live "a run that costs $10.00 is charged
    $13.00" line;
  - included models with their current prices, marked BY HAND or DEFAULT;
  - an optional "Assign it now" organization picker.
- **Models & prices:**
  - the read status line;
  - a "Read now" button;
  - an alert for prices that are by hand or failed to read;
  - a table with inline price fields, saved on blur through a Stimulus controller and a
    PATCH;
  - the last read per model, with IN USE and BY HAND markers.
- **Organizations:**
  - the billing table from `organizations.html`: organization (link), plan or an inline
    "Assign" picker, margin, cost, price, a bar against the limit, runs, and an UNKNOWN
    count;
  - the three notes below it;
  - the existing "New organization" button stays.
- **Organization** (`organization.html`):
  - cost, price and margin kept;
  - the bar against the limit;
  - by area (cost → price);
  - by project (cost → price), and own key "billed to them";
  - a note on unknown runs. It lists them, and each one has a "Looked at" action that sets
    `unknown_reviewed_at`. The UNKNOWN flags on Organizations count only the runs not
    looked at yet. My call (builder check): that is what "flagged here until somebody has
    looked at them" asks for, and the flag is how "Flosis has been told". There is no
    Discord or email;
  - runs with model, cost, margin and price.
- My call: the existing organization sections (People, Settings, Projects) move below the
  billing part on the same page, unchanged.

**Assigning a plan** sets `ai_plan_id` and `ai_plan_assigned_at`. Past runs keep their
margin.

### 7. Retention

Usage records are kept indefinitely. They are small, and invoicing will need them. This
answers the ticket's open question; it is my call.

## Left to the builder

- Component markup. Port it from the design repo's components (`area-cost`,
  `consumption-*`, `ai-costs-card`, `flosis-admin-shell`, `chat-panel`, `ready-panel`,
  `pr-review-row`, `estimate-row`, `bug-row`, `sidebar`) into the app's ERB and `clar-*`
  classes. Follow the screens, and replace € with $.
- Query shapes for the sums (`AiRun` scopes), as long as Consumption's numbers add up and a
  page does not run N+1 queries over items. Batch item figures per page with one grouped
  query.
- How "Show 50 more" paginates.
- Test structure (Minitest): service recording, including INT on a fake CLI script; every
  call site's attribution; the formatter; visibility; Consumption sums; and the hidmin
  pages.

## Deviations (as built, 2026-11-22)

- **`Designs::SetupRunJob`'s `pkill` keeps sending TERM.** That process's job is dead, so
  nobody would read an INT result. The sweeper fails its row, as §2 accepts.
- **Item figures are loaded by a view helper.** `ai_figures(records, area:)` makes one
  grouped query per list, and none while costs are hidden. Controllers do not set them.
- **Hints use `.clar-tip`, not `title`.** This follows Kacper's fast-hover rule.
- **Profile → AI costs is in the page's m3 markup**, with a new `.m3-switch`. The Profile
  page is not in the Workshop design system.
- **Staff figures come from `AiBilling`** (cost, price and margin). `AiCosts` stays
  price-only, so no organization screen can show cost by accident.
- **The Organizations list in `/hidmin` is the billing table.** Its old PEOPLE and PRODUCTS
  columns live on each organization's page.
- **A table row whose runs all reported no cost reads "unknown"**, never $0.00.
- **"Show 50 more" on Consumption is a Turbo-frame link** at the end of the list.
