# Invoicing and payments (SCRUM-71): technical design

Product spec: `tasks/SCRUM-71/scrum-71.md` (description v2). Designs: flosis-app-design
merge `88cdd2d` (`designs/admin/billing.html`, `designs/emails/*.html`, the
`ai-paused` states of idea/process/bugs, `designs/admin/consumption.html`,
`designs/flosis-admin/organization.html`). This document records how it is built
and every decision the product spec leaves open. Organizations are `Workspace`.

## Decisions taken without Kacper (2026-11-23, to confirm)

1. **Stripe stores the card; Flosis runs the billing.** Not Stripe Subscriptions.
   Stripe Checkout (mode `setup`) saves the card on Stripe's page; every charge is a
   PaymentIntent Flosis creates for an amount it computed. Proration by days,
   upgrade differences, downgrades on the 1st, the 7-day retries, the 15% grace,
   top-ups and the invoice-after-success rule all live in Flosis, so there is one
   source of truth next to the KSeF invoices. No Stripe invoices, no webhooks: every
   charge is confirmed synchronously, a 3-D Secure challenge on a charge an admin
   makes in the browser returns through `return_url`.
2. **No plan (none, not activated yet, ended): AI paused** (Kacper, 2026-11-24),
   unless Flosis staff turn on **Free AI** for the organization in /hidmin
   (`workspaces.free_ai`, off for new organizations; the migration turns it on for
   every organization that exists, so nothing stops at deploy).
3. **While a payment is failing** (Kacper, 2026-11-24): 15% of the plan price, then
   the top-up balance as a buffer, then paused. Once the month is paid, what the
   top-up paid meanwhile becomes the plan's (plan margin, up to the paid limit) and
   the balance gets it back. The plan's month never carries over.
4. **Retries**: the first attempt on the 1st is day 1; retries on days 3, 5 and 7
   ("Retrying · day 3 of 7"). Each failed attempt emails the admins. After day 7 the
   charge is *unpaid*; changing the card charges it at once. On the next 1st a still
   unpaid charge is abandoned (never invoiced) and the new month is charged.
5. **Seller: Ruby on SaaS Sp. z o.o., ul. Dalanowska 46/117, 03-566 Warszawa, NIP
   5242954651** (Kacper, 2026-11-24; ENV `INVOICE_SELLER_*` overrides it, which KSeF
   TEST needs). Numbers follow the company's format `PREFIX/NNN/MM/YYYY` (theirs:
   FV/005/11/2026), gap-free per month; `INVOICE_NUMBER_PREFIX` defaults to `FS` (Flosis,
   Kacper 2026-11-24): FS/001/11/2026, a series of its own.
6. **Monthly charge at 06:00 Warsaw on the 1st** (the design's emails say 06:0x);
   until it runs, the new month counts as paid.
7. **Runs before release** get `funding = "legacy"` in the migration and never touch a
   limit or a balance; a legacy run whose cost staff set later stays legacy.

## Data

- `billing_accounts` (one per workspace): company name, street, postal code, city,
  country code, VAT number, `vat_checked_at`; Stripe customer and payment method ids,
  card brand/last4/expiry; `plan_state` (`none` `pending` `active` `cancelling`
  `ended`), `pending_ai_plan_id` (downgrade on the 1st), `plan_started_on`,
  `plan_ends_on`; `auto_top_up` + `auto_top_up_usd` (100/200/300); notice markers
  `usage_80_notified_on`, `paused_notified_at`.
  `workspaces.ai_plan_id` stays the current plan (Consumption and `AiMonthLimit` read it).
- `billing_charges`: every attempt to take money. `kind` (`plan` `upgrade` `top_up`
  `auto_top_up`), `status` (`pending` `requires_action` `succeeded` `failed` `abandoned`),
  plan id + name + full monthly price, `period_month`, `period_from`, `period_to`,
  net/VAT/gross USD, `vat_rate`, `vat_treatment` (`pl_23` `eu_reverse_charge` `non_eu`),
  Stripe PaymentIntent id, `failure_message`, `attempts`, `first_failed_at`,
  `next_retry_on`, `paused_notified_at`, `created_by_id`, `succeeded_at`.
- `invoices`: one per succeeded charge (unique `billing_charge_id`), `number`
  (unique), issued/sold on, the line, buyer snapshot, amounts, NBP rate (+ its date
  and table) and VAT in PLN, `ksef_status` (`pending` `sent` `failed`), KSeF number,
  error, reference, attempts, the exact XML sent (its hash is in the QR code),
  `emailed_at`.
- `invoice_counters` (month, last number).
- `ai_runs.funding`: `plan` (counts toward the month's limit), `top_up` (paid from the
  balance, priced cost + 30%), `free` (no running plan), `legacy` (before release),
  nil while running or while the cost is unknown.
- `ai_month_limits.starts_on`: a partial month reads "of $110.00 · 20–30 Nov".

## Money

- `Billing::Proration`: days left including today; amount = price × days left ÷ days
  in month, to the cent. 20 Nov, $300 → 11/30 → $110. Upgrade on day 16 of 30,
  $300 → $600: $150, limit $300 + $150 = $450.
- `Billing::Vat.for(account)`: PL → 23%; EU country with a VIES-valid VAT number →
  reverse charge 0%; outside the EU → not subject to Polish VAT 0%. An EU buyer
  without a valid VAT number cannot save details (only companies can buy).
- Balance = succeeded top-up nets − prices of `top_up` runs. It can dip below zero by
  the run that was already going; the next top-up covers it.
- Plan spend = prices of the month's `plan` runs. A month's limit = what was paid
  (`AiMonthLimit.limit_usd`: activation prorated, + upgrades); staff repricing a plan
  no longer moves a billed month's limit.

## Allowance (the gate)

`Billing::Allowance.for(workspace)` → open, or paused with a reason:
`limit` (plan spend ≥ limit and balance ≤ 0), `retry_spent` (charge failing, plan
spend ≥ 15% of the plan price), `unpaid` (failing past day 7). Checked:
- in `ClaudeCliService#recorded` before `Recorder.start!` (raises
  `ClaudeCliService::PausedError < ClaudeCliError`), unless the run is own-key: the
  hard gate, every run passes it;
- before side effects in chats (`ChatStreaming#create`/`#message`), Designs
  (`Designs::Threads` actions, setup/import starts), and the buttons that only
  enqueue a job (Re-estimate, Analyze, Run now, refresh features);
- by the automatic jobs (PR review check, alert dispatch, Jira-sync estimates and bug
  analyses, feature scan), which skip a paused workspace and leave "Skipped: AI paused"
  where the screen lists runs.
Designs projects on their own Anthropic key are never paused.

## Run funding

`Billing::Funding.assign!(run)` after `Recorder.finish!` prices a run (and when staff
set an unknown run's cost): own-key → nothing; no running plan → `free`; payment
failing or plan spend before the run < limit → `plan`; otherwise `top_up` at cost +
30%. Then: 80% notice (once a month), auto top-up (balance ≤ 0, on, fewer than 3 this
month, none in flight), paused notice (once per pause).

## Charges

`Billing::Charger` creates the charge row, computes VAT, calls the gateway, then on
success applies its effect (plan → month limit; upgrade → limit += net and switch
plan; top-up → balance) and issues the invoice; on failure records it. Gateway:
`Billing::StripeGateway` (stripe gem) behind `Billing.gateway`, a fake in tests.
- Activate (details + card + plan): prorated charge now.
- Upgrade: prorated difference now; downgrade: `pending_ai_plan_id`, applied on the 1st.
- Cancel: `cancelling` until the month ends; Keep plan undoes it; on the 1st it ends.
- `Billing::MonthStartJob` (06:00 on the 1st): abandon unpaid, end cancelled plans,
  apply downgrades, charge every active plan. `Billing::RetryJob` (daily 06:30).
- Card change: retry a failing plan charge at once.

## Invoices and KSeF

`Invoice.issue!(charge)` (number, buyer snapshot, NBP rate of the working day before
when VAT > 0) → `Ksef::SendInvoiceJob`: FA(3) XML → KSeF → accepted: KSeF number,
PDF (Prawn, KSeF number + KOD I QR) emailed to every admin; rejected/failed: staff
email, Retry in hidmin. KSeF module: `app/services/ksef/` (ENV `KSEF_ENV`,
`KSEF_NIP`, `KSEF_TOKEN` or `KSEF_CERT_PATH`/`KSEF_KEY_PATH`/`KSEF_KEY_PASSWORD`).

## Screens

Settings (sidebar label; `config-header` with Billing · Consumption | project tabs for
organization admins); Billing tab (`/workshop/billing`); Consumption under Settings
with balance figures and the paused block; banners above the top bar for admins
(payment failed red; 80%, paused, automatic top-ups paused amber); paused Claude card;
paused note + disabled controls in chats, Agents & Automations, Bug Reporting;
hidmin organization Payments & invoices with KSeF status and Retry; usage statement
PDFs; emails per `designs/emails/*`.

## As built (2026-11-23)

- **Stripe, checked against the sandbox** (Ruby on SaaS sp. z o.o. sandbox, PL, PLN
  default): Checkout in setup mode saves the card (filled with 4242 on Stripe's real
  page), PaymentIntents take the charge. Since API 2026-09-30 Stripe refuses
  `payment_method_types`; the gateway sends `allowed_payment_method_types: ["card"]`.
  Decline (insufficient funds, expired card) and 3-D Secure (redirect, then
  `payment_return`) come back as the gateway says. No webhooks are needed.
- **Idempotency keys** read `flosis-<organization>-<what>-<YYYYMMDD-HHMMSS the row was
  made>-<row id>[-<attempt>]`, e.g. `flosis-acme-inc-plan-20261201-060012-12-1` (Kacper,
  2026-11-24). One sandbox serves several databases, so a bare row id is not enough.
  A charge keeps its last attempt's key (`billing_charges.stripe_key`, also in the
  payment's metadata as `flosis_key`); a payment whose outcome was unknown is looked
  up by it 10 minutes later and never sent again.
- **KSeF, checked against the Ministry's TEST environment**: FA(3) invoices for all
  three VAT treatments were accepted (self-signed certificate on TE; token login also
  works). The KOD I link opens "Faktura znajduje się w KSeF". `rake ksef:smoke`.
- **Configuration (ENV)**: `STRIPE_SECRET_KEY` (falls back to
  `STRIPE_SANDBOX_SECRET_KEY`), `INVOICE_SELLER_NAME/NIP/STREET/POSTAL_CODE/CITY`,
  `INVOICE_NUMBER_PREFIX` (FV), `KSEF_ENV` (test/demo/production), `KSEF_NIP`,
  `KSEF_TOKEN` or `KSEF_CERT_PATH` + `KSEF_KEY_PATH` (+ `KSEF_KEY_PASSWORD`),
  `BILLING_MAIL_FROM`.
- **Deviations from the designs**: the invoice PDF link shows "Soon" until KSeF has
  the number (the PDF must carry it); the paused note says "payment not through" when
  the pause is a failed payment rather than the limit; flashes say "The invoice is on
  its way to every admin" (it is emailed once KSeF accepts it, not at the charge).
- **Open, for Kacper / the accountant**: the reverse-charge wording; production KSeF
  credentials and live Stripe keys. NBP: the last working day before (Kacper agreed).
