# SCRUM-70 Add token calculations

Description v5 · 22 Nov 2026 · from Flosis
- Jira: https://rubyonsites.atlassian.net/browse/SCRUM-70
- Designs (sign in to Flosis): https://app.flosis.com/flosis/flosis/SCRUM-70/design
- Design code: https://github.com/RubyOnSaas-wiki/flosis-app-design/commit/ed2d5e90ad6a19a9363494bf7b4d5630df420193
  The screens this task changed, in that repo: designs/admin/bugs.html, designs/admin/configuration.html, designs/admin/configuration-costs-off.html, designs/admin/consumption.html, designs/admin/consumption-all-time.html, designs/admin/consumption-no-plan.html, designs/admin/consumption-over-limit.html, designs/admin/pipeline.html, designs/admin/process.html, designs/admin/process-alerts.html, designs/admin/process-estimate.html, designs/admin/profile.html, designs/admin/profile-costs-off.html, designs/admin/profile-organizations.html, designs/admin/profile-password-error.html, designs/admin/profile-saved.html, designs/flosis-admin/models.html, designs/flosis-admin/organization.html, designs/flosis-admin/organizations.html, designs/flosis-admin/plan-new.html, designs/flosis-admin/plans.html

## AI usage and cost per organization

Flosis runs Claude in many places (task conversations, PR reviews, estimates, agents, Designs, bug analysis), but nothing about those runs is saved, so we can't say what an organization, a project or a single run cost. We're moving to billing by token usage: every AI run is recorded and priced, and the organization can see what it spent. Invoicing and payments are the next ticket.

**Designs** · [Open the designs](https://app.flosis.com/flosis/flosis/SCRUM-70/design) · merge commit [ed2d5e9](https://github.com/RubyOnSaas-wiki/flosis-app-design/commit/ed2d5e90ad6a19a9363494bf7b4d5630df420193)
- New (11): Admin › [Configuration — AI costs hidden for everyone](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/configuration-costs-off.html), Consumption — [this month](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/consumption.html), [all time](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/consumption-all-time.html), [no plan](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/consumption-no-plan.html), [over the limit](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/consumption-over-limit.html), [Profile Settings — costs off for everyone](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/profile-costs-off.html) · Flosis-admin › [Models & prices](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/flosis-admin/models.html), [Flosis Sp. z o.o. — cost and price](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/flosis-admin/organization.html), [Organizations](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/flosis-admin/organizations.html), [New plan](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/flosis-admin/plan-new.html), [Plans](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/flosis-admin/plans.html)
- Updated (10): Admin › [Bug Reporting](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/bugs.html), [Configuration — AI](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/configuration.html), [Create Tasks](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/pipeline.html), [AI PR Reviews](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/process.html), [AI Agents & Alerts](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/process-alerts.html), [AI Estimate](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/process-estimate.html), [Profile Settings](https://app.flosis.com/flosis/flosis/SCRUM-70/design/designs/admin/profile.html) (+3 states)
- Through shared components: sidebar, designs imports page, chat panel, ready panel and 5 more

**Plans (Flosis admin)**

- Admin creates a plan: name, monthly price and margin in %.
- Admin picks the AI models the plan includes from a list (Anthropic only for now) and sees each model's current price per 1M tokens (input, output, cache). Prices refresh daily.
- A plan is assigned to an organization. The plan price is the organization's monthly limit.
- Plans, Models & prices and Organizations sit in a separate Flosis-admin area for Flosis staff, not in an organization's admin.

**Recording**

Every AI run records: organization, project, area and item (which conversation, PR, estimate, agent, design thread, import or bug), model, tokens (input, output, cache), cost, date, and who started it: a person, or the automation's name.

- Failed, timed-out or stopped runs record what they used up to that point.
- A run keeps the margin from the day it ran; later changes, including a margin change mid-month, don't change it.
- A run that reports no cost still records its tokens; its cost shows as "unknown" and is flagged to the admin, never counted as 0.
- Projects on their own Anthropic key are recorded too, marked "own key", and don't count toward the limit.
- When an item is deleted, its usage stays in the project and organization totals.

**Two amounts**

- Cost: what the provider reports the run cost (not calculated from the price list). Visible to Flosis admin only.
- Price: cost + the plan's margin (e.g. cost €10, margin 30% → price €13). This is what the organization sees and what counts toward its limit.
- All amounts are in euro.
- The organization never sees the margin; it is shown only on the Flosis-admin screens.

**Cost of a single item**

Shown on the item itself: total so far, with this month in brackets only when it differs, e.g. "€12.40 (€3.23 this month)", "€0.74 (none this month)", or just "€0.68" when all of it was spent this month.

- Each task conversation, incl. the handoff written when a new task starts from it
- Each PR review
- Each AI estimate
- Each design conversation, incl. conflict fixes and components made in it
- Each design import
- Each bug analysis

**Monthly cost per area**

Shown in each area's own tab, on the page-title row, aligned right: what the whole area cost in a chosen month.

- Task conversations
- PR reviews
- AI estimates
- Agents and alerts
- Designs and imports
- Bug analysis

**Display**

- Costs are hidden by default. Each person can turn them on in their profile.
- An organization switch in Configuration → AI turns cost display off for everyone; the personal setting only works while it is on.
- Light and minimal: small, muted text that doesn't compete with the content.
- No new lines, cards or links to Consumption on working screens: the figure rides on a line or row that already exists.

**Consumption (organization admins only)**

A new item in the sidebar's ADMIN group with everything in one place, for any calendar month and all time:

- Total against the plan limit
- Per area: the six above, plus Chat with AI on a ticket, project feature scan and anything else that uses AI
- Per project
- List of runs with price, date and who started it

**Rules**

- Areas and projects add up to the organization total.
- Month = calendar month. Past months never change.
- Going over the limit blocks nothing; Consumption shows "over the limit by X".
- An organization with no plan still records usage; Consumption shows "no plan".

**Out of scope**

Invoicing and payments, blocking at the limit, letting users choose a model, pricing runs from before this ships, a plan changed mid-month (the billing ticket).

**Acceptance criteria**

- [ ] Every AI run creates a usage record with the fields under Recording.
- [ ] A failed or stopped run still leaves a record with its tokens.
- [ ] An automation's run names the automation, not a person.
- [ ] Admin can create a plan with a price and margin, pick its models, see their current prices, and assign the plan to an organization.
- [ ] A run's cost is the cost the provider reports; its price = that cost + the plan margin from the day it ran.
- [ ] Each task conversation, PR review, AI estimate, design conversation, design import and bug analysis shows its cost as "€12.40 (€3.23 this month)", or just "€12.40" when the month is the same amount.
- [ ] Each area's tab shows the area's cost for a chosen month.
- [ ] Costs are hidden by default and appear once a person turns them on in their profile; with the organization switch off, nobody sees them.
- [ ] Consumption is visible to organization admins only and shows every area (incl. project feature scan), every project and the total against the plan limit, per month and all time; the numbers add up.
- [ ] Going over the limit blocks nothing and is shown in Consumption.
- [ ] A run with no reported cost shows "unknown", not 0.
- [ ] Own-key projects are recorded, marked and excluded from the limit.
- [ ] Deleting an item keeps its usage in the project and organization totals.

**Open questions**

- Where do daily prices come from? Anthropic's API has no price list. Fallback: admin enters prices by hand.
- How long do we keep usage records?