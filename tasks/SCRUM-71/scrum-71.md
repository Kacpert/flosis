# Invoicing and payments 

Description v2 · 23 Nov 2026 · from Flosis
- Jira: https://rubyonsites.atlassian.net/browse/SCRUM-71
- Designs (sign in to Flosis): https://app.flosis.com/flosis/SCRUM-71
- Design code: https://github.com/RubyOnSaas-wiki/flosis-app-design/commit/88cdd2ded1410f426fe447293efc247f9553481c
  The screens this task changed, in that repo: designs/admin/billing.html, designs/admin/bugs.html, designs/admin/consumption.html, designs/admin/idea.html, designs/admin/process.html, designs/admin/process-alerts.html, designs/admin/process-estimate.html, designs/emails/invoices.html, designs/emails/payments.html, designs/emails/staff.html, designs/emails/usage.html, designs/flosis-admin/organization.html, designs/product-manager/bugs.html, designs/product-manager/idea.html, designs/product-manager/process.html, designs/product-manager/process-alerts.html, designs/product-manager/process-estimate.html, designs/product-owner/bugs.html, designs/product-owner/idea.html, designs/product-owner/process.html, designs/product-owner/process-alerts.html, designs/product-owner/process-estimate.html

Flosis records and prices every AI run (SCRUM-70), but it doesn't charge organizations, issue invoices or stop usage at the limit. This ticket adds upfront monthly card payments through Stripe, invoices sent through KSeF, top-ups, and blocking at the limit. Letting users choose a model comes next, in its own ticket.

**Designs** · [Open the designs](https://app.flosis.com/flosis/SCRUM-71) · merge commit [88cdd2d](https://github.com/RubyOnSaas-wiki/flosis-app-design/commit/88cdd2ded1410f426fe447293efc247f9553481c)
- New (5): Admin › [Settings — Billing](https://app.flosis.com/flosis/SCRUM-71/admin/billing) · Emails › [Invoice emails](https://app.flosis.com/flosis/SCRUM-71/emails/invoices), [Payment emails](https://app.flosis.com/flosis/SCRUM-71/emails/payments), [Flosis staff emails](https://app.flosis.com/flosis/SCRUM-71/emails/staff), [AI limit emails](https://app.flosis.com/flosis/SCRUM-71/emails/usage)
- Updated (17): Admin › [Bug Reporting](https://app.flosis.com/flosis/SCRUM-71/admin/bugs), [Settings — Consumption](https://app.flosis.com/flosis/SCRUM-71/admin/consumption), [Briefing](https://app.flosis.com/flosis/SCRUM-71/admin/idea), [AI PR Reviews](https://app.flosis.com/flosis/SCRUM-71/admin/process), [AI Agents & Alerts](https://app.flosis.com/flosis/SCRUM-71/admin/process-alerts), [AI Estimate](https://app.flosis.com/flosis/SCRUM-71/admin/process-estimate) · Flosis admin › [Flosis Sp. z o.o. · Flosis admin](https://app.flosis.com/flosis/SCRUM-71/flosis-admin/organization) · Product Manager › [Bug Reporting](https://app.flosis.com/flosis/SCRUM-71/product-manager/bugs), [Briefing](https://app.flosis.com/flosis/SCRUM-71/product-manager/idea), [AI PR Reviews](https://app.flosis.com/flosis/SCRUM-71/product-manager/process), [AI Agents & Alerts](https://app.flosis.com/flosis/SCRUM-71/product-manager/process-alerts), [AI Estimate](https://app.flosis.com/flosis/SCRUM-71/product-manager/process-estimate) · Product Owner › [Bug Reporting](https://app.flosis.com/flosis/SCRUM-71/product-owner/bugs), [Briefing](https://app.flosis.com/flosis/SCRUM-71/product-owner/idea), [AI PR Reviews](https://app.flosis.com/flosis/SCRUM-71/product-owner/process), [AI Agents & Alerts](https://app.flosis.com/flosis/SCRUM-71/product-owner/process-alerts), [AI Estimate](https://app.flosis.com/flosis/SCRUM-71/product-owner/process-estimate)
- Through shared components: sidebar, config header, chat panel, banner

## Settings → Billing (organization admins only)
- The sidebar's "Configuration" becomes "Settings". Its tabs read "Billing · Consumption | Integrations · AI · Create Tasks · Users", with a thin divider between the organization tabs and the project tabs.
- Billing is a new tab for admins. Only organization admins see Billing, Consumption and the divider.
- **Billing details**, required before the first charge: company name, address, country, and VAT number (NIP for Polish companies). Without them, the plan can't start and the tab says "Add billing details to activate your plan".
- **Card**: added and changed through Stripe's own secure page. The tab shows "Visa •••• 4242, expires 08/28" and a "Change card" button.
- **Plan**: name, monthly price and next charge date, e.g. "Team, $300 a month · next charge 1 Dec 2026". Admins pick and change the plan here. Prices are shown before VAT.
- **Top-ups**:
  - "Buy top-up" with $100, $200 or $300, charged straight away.
  - A "Top up automatically" checkbox, off by default, with the same three amounts.
  - The current balance, e.g. "Top-up balance: $140.00".
  - The automatic top-up status, e.g. "Automatic: $100 · 1 of 3 this month" or "Paused until 1 Dec · 3 of 3 used".
- **Invoices**: a list, newest first, of date, number, type (Plan or Top-up), amount and a PDF download, e.g. "21 Nov 2026 · FV/2026/11/0042 · Top-up · $200.00 · PDF". It has no status, since only paid charges are invoiced. Empty state: "No invoices yet".
- **Usage statements**: one per closed month, with each project and its price plus the organization total, as a PDF. This is a breakdown, not a tax invoice.
- **Cancel plan**: the plan stays active until the end of the paid month, and nothing is charged afterwards. The plan then reads "Team, $300 a month · ends 30 Nov 2026, nothing charged after", with "Keep plan" until then and "Renew plan" after. Nothing is removed.

## Consumption (existing screen, now under Settings)
- Next to the limit, it shows the top-up balance and how much of it was used this month, e.g. "$300.00 of $300.00 · top-up $60.00 of $200.00 used", or just "$163.20 of $300.00" with no balance. A partial month reads "of $110.00 · 20–30 Nov".
- "Over the limit by X" is replaced by the blocked state: "AI paused: limit reached. Top up in Billing."

## Banners and emails (admins)
- Banners show above the top bar on Workshop screens.
- **80% of the limit**: an amber banner on Workshop screens and one email: "You've used 80% of this month's AI limit ($240 of $300)."
- **Limit reached with no balance left**: an amber banner and email linking to Billing.
- **Payment failed**: a red banner and email "Payment failed, update your card. AI stays on up to $45.00 until it's paid.", repeated at every retry.
- **Automatic top-up done**: an email "We topped up $100", with the invoice attached.
- **3rd automatic top-up of the month done**: the email says automatic top-ups are paused until next month.

## Blocking AI
- When an organization is blocked, starting any AI run in Workshop shows the paused message. A run already in progress finishes, even if it takes the total slightly over.
- The paused message ends in "Top up in Billing." for admins and "Ask an admin to top up." for everyone else.
- The sidebar's Claude card turns amber: "Claude Opus · paused" / "AI limit reached · back on 1 Dec or after a top-up".
- In conversations (such as Briefing), the paperclip, message box, Send, Reset session and New task are greyed out, and the box reads "AI paused: limit reached".
- Agents & Automations (all three tabs) shows "AI paused: limit reached. PR reviews, estimates and alert rules don't run until an admin tops up.", with "Run now" and "Re-estimate" greyed out.
- Bug Reporting shows the same amber line above Bug analysis, with "Analyze" greyed out.
- Time & HR never gets blocked.
- Runs on a project's own Anthropic key are never blocked and never charged, as today.

## Flosis admin (hidmin)
- Each organization's billing shows payment status (Paid, Retrying with day X of 7, e.g. "Retrying · day 3 of 7", Unpaid, Cancelled), top-up balance, automatic top-ups this month, and every invoice with its KSeF status (Sent with KSeF number, Failed with the reason).
- A failed KSeF send can be retried with one click. Staff get an email when a send fails.

## Rules
- **All amounts are in US dollars**, which is what plans already use.
- **Upfront charge**: the plan price is charged on the 1st of each month for that month.
- **Partial first month**: the charge and the limit are both proportional to the days left. Joining on 20 Nov with a $300 plan gives 11 of 30 days, so $110 is charged and the month's limit is $110. From 1 Dec it's the full $300.
- **The invoice only exists after a successful charge.** It's then sent to KSeF and emailed to all admins as a PDF carrying the KSeF number and QR code. This is required for foreign customers, who can't open KSeF. A failed charge never creates an invoice.
- **Failed payment**: Stripe retries the card over 7 days. During those 7 days the organization can use up to 15% of its plan price ($45 on a $300 plan), then AI pauses. After 7 days unpaid, AI pauses until the charge succeeds. Once it succeeds, the full limit applies again.
- **At the limit**: the top-up balance is used first. Runs paid from it are priced at cost + 30%, not the plan's margin (a run costing $10 takes $13). With no balance left, the organization is blocked until the 1st, unless automatic top-up is on.
- **Automatic top-up**: when the limit is reached and the balance runs out, the chosen amount is charged. That's at most 3 times per calendar month. After the 3rd, AI is blocked until someone tops up by hand or the month ends. If an automatic top-up charge fails, AI is blocked and admins get an email.
- **Top-ups** never expire and are never refunded. They're only used after the plan limit is reached, and they carry over between months.
- **Plan changed mid-month**:
  - An upgrade starts immediately. The difference for the days left is charged (plus VAT) and added to this month's limit: going from $300 to $600 on day 16 of 30 charges $150, and the limit becomes $450.
  - A downgrade starts on the 1st of next month.
  - When staff edit a plan's price, the new price applies from the next charge. This month's limit stays at what was paid.
- **Unknown-cost runs** count toward the limit and the balance only once staff set their cost. They're never charged separately.
- **Runs from before this ships** are never charged. They keep showing in Consumption and the usage statements as today.
- **No plan**: nothing is charged and nothing is blocked, as today.
- **VAT**:
  - Only companies can buy; EU consumers can't.
  - Prices are shown before VAT, and VAT is added to the charge and the invoice, e.g. "$246.00 with 23% VAT".
  - Polish customers pay 23% VAT.
  - EU businesses with a valid EU VAT number get a reverse charge.
  - Customers outside the EU get an invoice that isn't subject to Polish VAT.
  - The VAT amount is also shown in PLN, at the NBP exchange rate from the working day before the invoice.

## External dependencies
- **Stripe**: an account for the Polish sp. z o.o., using Stripe's subscription billing. We need its keys for test and live mode.
- **KSeF**: Flosis's own KSeF authorization (a token or certificate for the company's NIP). Testing uses the Ministry of Finance's KSeF test environment before going live.

## Out of scope
Letting users choose a model (its own ticket), removing projects' own Anthropic keys, clients buying their own credits, and refunds.

## Acceptance criteria
- [ ] An admin can't activate a plan without billing details and a card, and members who aren't admins don't see Billing or Consumption.
- [ ] On the 1st, the plan price is charged, and the invoice reaches KSeF and the admins' inbox only after the charge succeeds.
- [ ] A failed charge creates no invoice, shows the banner, and allows 15% of the plan price before AI pauses. After 7 days unpaid, AI stays paused until payment.
- [ ] Joining on 20 Nov with a $300 plan charges $110 and sets a $110 limit.
- [ ] At 80%, admins get one email and see a banner. At 100% with no balance, new AI runs are blocked, a running one finishes, and Time & HR still works.
- [ ] A $200 top-up is charged, invoiced through KSeF, shows as a $200 balance, and is only used after the limit, at cost + 30%.
- [ ] Automatic top-up fires when the balance runs out, at most 3 times a month, then blocks AI.
- [ ] An upgrade on day 16 of 30 from $300 to $600 charges $150 and raises the limit to $450. A downgrade applies from next month.
- [ ] Unknown-cost runs don't reduce the limit or balance until staff set their cost. Runs from before release are never charged.
- [ ] A failed KSeF send shows in hidmin with its reason, and staff can retry it.
- [ ] A closed month's usage statement lists each project's price and the organization total.

## Open questions
- **Who holds the KSeF authorization and the Stripe account.** Proposal: the company sets both up and hands the keys to the developer, starting with the test environments.