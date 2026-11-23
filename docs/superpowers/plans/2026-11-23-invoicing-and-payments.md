# Invoicing and Payments (SCRUM-71) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Organizations pay for their AI plan upfront by card (Stripe), get KSeF invoices, buy top-ups, and are paused at the limit.

**Architecture:** Flosis computes every amount and charges a card saved on Stripe (PaymentIntents, no subscriptions); a charge that succeeds applies its effect and issues an invoice that goes to KSeF and then to the admins. One allowance predicate gates every Claude run in `ClaudeCliService#recorded`; each finished run is funded from the plan or the top-up balance.

**Tech Stack:** Rails 8.1, Minitest, stripe gem, Prawn + rqrcode, Nokogiri/OpenSSL (KSeF), SolidQueue recurring jobs. Tests on PostgreSQL, production MariaDB.

**Spec:** `docs/superpowers/specs/2026-11-23-invoicing-and-payments-design.md` + `tasks/SCRUM-71/scrum-71.md` + designs repo merge `88cdd2d`.

## Global Constraints

- All amounts in US dollars, two decimals on charges/invoices; prices shown before VAT.
- Portable SQL only (MariaDB in production): no FILTER, date_trunc, jsonb, partial indexes; extend `test/models/ai_sql_portability_test.rb` for new queries.
- Workshop screens only (layout `workshop`, clar classes); never touch Time & HR views.
- Copy is the designs' copy, verbatim where the design gives it.
- Slow buttons (Stripe, charges) show what they are doing at once (designs-accepting pattern).
- Hints use `.clar-tip`, not `title`.
- Tests: one file at a time, `DATABASE_URL=postgres://localhost/gold_test_scrum71 bin/rails test <file>`.
- Commits on `feat/scrum-71-invoicing-and-payments`, explicit paths, English messages, no Claude trailers.

## Review Focus

- A run finishing while another run's auto top-up is in flight: never two auto top-ups (lock + recheck).
- Admin double-clicks Pay / Activate: one charge (disable on submit + idempotency key per charge row).
- Staff reprice a plan mid-month: a billed month's limit does not move; an unbilled one still follows (SCRUM-70 behaviour).
- An EU buyer types a VAT number VIES rejects or VIES is down: details not saved, plain message; nothing charged.
- KSeF down or unconfigured: the charge and invoice stand, the customer email waits, staff are told, Retry works.

---

### Task 1: Data model and money rules
**Files:** migration `db/migrate/20261123100000_create_billing.rb`; models `billing_account.rb`, `billing_charge.rb`, `invoice.rb`, `invoice_counter.rb`; `workspace.rb` (`has_one :billing_account`, `admin_users`); `app/services/billing/proration.rb`, `vat.rb`, `eu.rb`; tests under `test/models/` and `test/services/billing/`.
**Produces:** `Billing::Proration.days_left(date) -> Integer`, `.amount(price, date) -> BigDecimal`, `.period(date) -> Range`; `Billing::Vat.for(account) -> Vat::Treatment(kind, rate, label, note)`; `Workspace#admin_users`; `BillingAccount#plan_running?`, `#details_complete?`, `#card?`, `#card_label`; `BillingCharge` scopes; `InvoiceCounter.next_number!(date) -> "FV/2026/11/0001"`.
- [ ] Tests: 20 Nov $300 → 11 days, $110.00; 16 Nov → 15 days, $600−$300 → $150.00; 22 Nov $200 → 9 days, $60.00; VAT PL 23% ($200 → $46.00), DE reverse charge, US non-EU; counter is gap-free and per month.
- [ ] Migration (portable), models, rules; run tests; commit.

### Task 2: VIES and NBP clients
**Files:** `app/services/billing/vies.rb`, `app/services/nbp_rate.rb`; tests with WebMock.
**Produces:** `Billing::Vies.check(country_code, number) -> Result(valid:, name:, error:)`; `NbpRate.usd_before(date) -> Rate(mid:, date:, table:)` (last table A before `date`, looks back 10 days).
- [ ] Tests: valid/invalid/down for VIES; NBP picks the working day before (weekend), raises `NbpRate::Unavailable` on failure; commit.

### Task 3: Gateway (Stripe) + fake
**Files:** Gemfile (`stripe`, `rqrcode`); `app/services/billing/stripe_gateway.rb`; `app/services/billing.rb` (`Billing.gateway`, settable); `test/test_helpers/fake_billing_gateway.rb`.
**Produces:** gateway methods `ensure_customer(account) -> String`, `card_setup_url(account, success_url:, cancel_url:) -> String`, `card_from_setup(account, session_id) -> Card(payment_method_id, brand, last4, exp_month, exp_year)`, `charge(account, cents:, description:, idempotency_key:, off_session:, return_url:) -> ChargeResult(status :succeeded|:failed|:requires_action, payment_intent_id, failure_message, redirect_url)`, `payment_result(payment_intent_id) -> ChargeResult`.
- [ ] Stripe keys from `STRIPE_SECRET_KEY`, falling back to `STRIPE_SANDBOX_SECRET_KEY`; WebMock tests for the request shapes (setup session mode, off_session confirm, decline → :failed with the bank's message); commit.

### Task 4: Charger and plan lifecycle
**Files:** `app/services/billing/charger.rb`, `plans.rb`, `top_ups.rb`; `ai_month_limit.rb` (`paid!`, `starts_on`); `ai_plan.rb` (skip billed workspaces); tests.
**Produces:** `Billing::Charger.new(account).charge!(kind:, net:, plan: nil, period: nil, user: nil, off_session: true, return_url: nil) -> BillingCharge`; `Billing::Plans.new(workspace, user:)` with `#choose!(plan)`, `#activate!`, `#cancel!`, `#keep!`, `#preview(plan) -> Preview(kind :current|:now|:next_month, net, limit_after, period)`; `Billing::TopUps.new(workspace, user:)#buy!(amount)`, `#auto!`; `Billing::Balance.for(workspace) -> BigDecimal`.
- [ ] Tests (fake gateway): activation charges prorated net + VAT and sets limit + starts_on; no details/card → raises `Billing::NotReady`; upgrade day 16 → $150 + limit $450; downgrade → pending, plan unchanged; cancel/keep; failed charge creates no invoice; top-up $200 → balance $200; staff reprice leaves billed month's limit.
- [ ] Commit.

### Task 5: Month start, retries, card change
**Files:** `app/jobs/billing/month_start_job.rb`, `retry_job.rb`; `config/recurring.yml`; tests.
- [ ] Tests: on 1 Dec active → full price charged; cancelling → ended + plan nil; pending downgrade applied then charged; failed → day 1, retries on 3/5/7, then unpaid; prior unpaid abandoned; card change retries at once; commit.

### Task 6: Allowance, funding, gate
**Files:** `app/services/billing/allowance.rb`, `funding.rb`; `ai_run/recorder.rb` (call funding); `claude_cli_service.rb` (PausedError gate); migration marks legacy; hidmin "Set cost" for unknown runs; tests in `test/services/claude_cli_service_recording_test.rb`, `test/services/billing/*`.
**Produces:** `Billing::Allowance.for(workspace) -> Allowance` with `paused?`, `reason`, `grace_usd`, `back_on`, `limit_usd`, `plan_spend`, `balance`, `percent_used`; `Billing::Allowance.paused_for?(workspace, project: nil, own_key: false)`; `ClaudeCliService::PausedError`.
- [ ] Tests: over limit no balance → paused, run refused, no AiRun row; own-key run not refused; balance > 0 → runs funded top_up at cost × 1.3; failing charge → 15% grace then paused; > day 7 → paused; no plan → open; unknown-cost run counts only once cost set; legacy never counted; commit.

### Task 7: Callers refuse nicely; automations skip
**Files:** `concerns/chat_streaming.rb`, `designs/threads.rb` + controllers, setup/import controllers, `ideas#estimate`, `bugs#analyze`, `alert_rules#run_now`, `configuration#refresh_features`, `pr_review_check_job.rb`, `alert_rules_dispatch_job.rb`, `jira_sync_service.rb`, `project_features_scan_job.rb`, JS (`task_chat_controller.js`, `breakdown_controller.js` show the error).
- [ ] Tests per entry point: paused → no job enqueued / no message saved / alert shown; automations skip paused workspaces; commit.

### Task 8: Settings shell
**Files:** `layouts/_clar_sidebar.html.erb` (Settings, no Consumption item, Claude card paused), `workshop/configuration/_header.html.erb` (new, from design config-header), `configuration/show`, `consumption/show`.
- [ ] Tests: admin sees Billing · Consumption tabs; member doesn't (and gets 404 on /workshop/billing); sidebar says Settings; commit.

### Task 9: Billing tab
**Files:** `app/controllers/workshop/billing_controller.rb` (+ routes), views `workshop/billing/*`, Stimulus `billing_controller.js` (country → VAT label/note, plan summary, top-up summary, auto amounts), tests.
- [ ] Every design state: not active, details modal, change plan modal with exact summaries, upgraded flash, top-up modal "Pay $246.00", auto on/paused lines, payment failed, cancel/cancelled/ended, invoices list + empty state, statements list; Stripe redirects (card setup return, 3DS return); commit.

### Task 10: Consumption, banners, paused UI
**Files:** consumption views; `layouts/workshop.html.erb` + `layouts/_billing_banners.html.erb`; chat panels (ideas, jira_tasks, designs thread), process header, bug list; helper `ai_paused_note`.
- [ ] Tests: banners per state for admins only; paused note admin vs member copy; controls disabled; Consumption "$300.00 of $300.00 · top-up $60.00 of $200.00 used", "of $110.00 · 20–30 Nov", paused block replaces over-limit; commit.

### Task 11: Emails
**Files:** `app/mailers/billing_mailer.rb`, `staff_mailer.rb`, views; triggers in Charger/Funding/Ksef job.
- [ ] Tests: invoice (plan/top-up/auto/auto 3 of 3) with PDF attached; payment failed (each attempt), paused; auto top-up failed; 80% once a month; paused once; KSeF failed to staff; commit.

### Task 12: Invoices, PDF, KSeF sending
**Files:** `invoice.rb#issue!`, `app/pdfs/invoice_pdf.rb`, `app/jobs/ksef/send_invoice_job.rb`, mapping `Invoice#to_ksef`; KSeF module from the parallel agent (`app/services/ksef/*`).
- [ ] Tests: issue! snapshots buyer, NBP rate when VAT > 0; job accepted → number + email; rejected → failed + staff email; retry; PDF contains number, KSeF number, VAT in PLN; commit.

### Task 13: Usage statements
**Files:** `app/pdfs/usage_statement_pdf.rb`, billing controller action.
- [ ] Test: closed month lists each project's price and the total; current month not offered; commit.

### Task 14: hidmin
**Files:** `hidmin/workspaces/show` (+ `_payments.html.erb`), `Hidmin::InvoicesController#retry_ksef`, `hidmin/ai_runs#set_cost`, index over-limit copy.
- [ ] Tests: Paid / Retrying · day 3 of 7 / Unpaid / Cancelled; invoice rows with KSeF Sent number / Failed reason + Retry; commit.

### Task 15: Whole-branch verification
- [ ] Full suite on a private DB (`PARALLEL_WORKERS=1`), SQL portability test, browser check of Billing/Consumption/paused screens, Stripe sandbox end-to-end (card setup, charge, decline 4000000000000002), KSeF TE send; deviations written into the spec.
