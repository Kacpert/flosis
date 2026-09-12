# Per-project permissions, configuration and projects

Date: 2026-09-12
Status: approved for planning

## Why

Everything a person may do is decided today at the level of the whole
workspace. One `role` column carries five values, and two boolean flags decide
which of the two products the person lands in. That worked while the company
ran one client and one repository. It no longer does.

A project is now the unit of work: it has its own Jira, its own repository,
its own automations and its own people. But its credentials are half in the
project and half in the workspace, and its people are not in it at all — you
are an administrator of everything or of nothing.

Two things follow from that, and both hurt in production. Someone who should
only refine briefs for one client either gets the keys to every project or
gets nothing. And there is no honest place to keep a second client's GitHub
token, because there is exactly one on the workspace.

This design moves permissions and configuration into the project, and reduces
the workspace to the one thing that genuinely belongs there: who is allowed to
create projects and run the HR module.

## Decisions taken before this document

- The heavier, architectural path — per-project permissions, per-project
  configuration, project creation and the HR/Workshop user split — is done as
  one piece of work rather than four.
- **A role is a label, not a stored value.** The set of granted permissions is
  the truth; the name is derived from it.
- The global privilege is an independent flag, not the top of a role ladder.
- Money visibility is its own sixth permission rather than being folded into
  Reporting.
- The Jira-only `client` role disappears. A client is a person whose only
  granted permission is Tasks.
- A Product Owner opens Configuration and sees every tab, but the ones they
  lack permission for are locked rather than hidden.
- An existing `workspace_client` becomes a Product Owner.
- `owner` disappears along with the rest of the role enum.

## The permission set

Six permissions, per user, per project. Order is the order they appear in the
interface; Briefing Configuration precedes Configuration.

| Permission | Column | Default when inviting |
| --- | --- | --- |
| Automations | `automations` | on |
| Tasks | `tasks` | on |
| Reporting | `reporting` | on |
| Pricing | `pricing` | off |
| Briefing Configuration | `briefing_config` | off |
| Configuration | `configuration` | off |

`Pricing` governs hourly rates, cost and revenue inside a project. It is
separate from `Reporting` because `Reporting` is granted by default, and
folding the two together would show every Project Manager the team's rates.

### Roles are derived

There is no role column. `PermissionPreset.label_for(granted_set)` compares the
granted set against a table of presets and returns the matching name, or
`Custom` when nothing matches exactly.

| Label | Granted set |
| --- | --- |
| Project Manager | automations, tasks, reporting |
| Product Owner | automations, tasks, reporting, briefing_config |
| Administrator | all six |
| Custom | anything else |

The role buttons in the invite dialog are presets: choosing one sets the
switches and has no other effect. Changing a switch afterwards is expected and
simply moves the label, possibly to `Custom`.

## Data model

### `project_memberships`

This table already records that a person is on a project, with their hourly
rate and a history of rate changes. It becomes the single record of a person's
involvement in a project and gains the six boolean columns above, all
`null: false` with the defaults from the table.

Presence of a row means "this person is on this project". Absence means they
cannot see it at all.

### `workspace_memberships`

Reduced to the global layer.

- `workspace_admin` (new, boolean, default false) — may create and delete
  projects, runs the HR module, manages the employee directory, and holds all
  six permissions on every project implicitly, so the workspace can never be
  locked away from its own administrator.
- `time_hr_access` (kept) — this person is in the HR module.
- `role` (dropped) — the five-value enum.
- `workshop_access` (dropped) — replaced by "has at least one project
  membership".

A workspace must keep at least one workspace admin. Removing or demoting the
last one is refused.

### `projects`

Gains the configuration that is currently shared across the whole workspace:

- `team` (string) — shown in the project switcher.
- `figma_token`, `figma_read_enabled`
- `anthropic_api_key` — the AI provider key, with the ambient environment as
  fallback.
- `pr_review_enabled`, `pr_review_prompt`, `pr_poll_minutes`, `pr_polled_at`
- `estimation_trigger`, `estimation_status_trigger`, `estimation_field_names`
- `jira_ai_actions_field_id`, `jira_ai_estimation_field_id`,
  `jira_story_points_field_id`
- `jira_status_ok`/`_error`/`_checked_at`, and the same triple for GitHub and
  Figma.

`github_repo`, `github_token`, `jira_site`, `jira_email`, `jira_api_token` and
`briefing_personas` are already on the project. Secrets are encrypted at rest,
following the existing `encrypts` declarations.

`discord_webhooks` gains `project_id`.

The workspace keeps only what is genuinely workspace-wide: its name,
`workshop_enabled`, `clients_enabled`, and the Discord channel used by the HR
time-logging reminders.

`ProjectCredentials` stays the single place that answers "what credentials does
this project use" and is extended to cover Figma and the AI key. Its fallback
to the workspace column is removed once the backfill has run, leaving only the
project column and, for Jira and the AI key, the environment.

## Authorization

All of it moves behind one object.

```ruby
ProjectAccess.new(user, project).can?(:configuration)
```

It returns true when the user is a workspace admin, otherwise it reads the
project membership. Controllers gate with `require_permission!(:tasks)`, which
resolves the project from `current_workshop_project`.

The existing predicates on `User` — `admin_or_owner?`, `client_role?`,
`workspace_client_role?`, `at_least_employee?`, `can_see_money?`,
`client_or_employee?`, `can_access_workshop?` — are removed, along with the
gates `require_workshop_config_access!`, `require_client_or_employee!`,
`require_workshop_member!` and `require_workspace_member!`.

`accessible_products`, `default_product` and `can_access_product?` survive with
their signatures intact and are reimplemented on the two new facts: HR access
is `time_hr_access`, Workshop access is having at least one project membership.

### Where each gate goes

The HR product keeps a workspace-wide gate, because its surfaces are not
per-project: a timesheet spans every project at once.

| Today | Becomes |
| --- | --- |
| `require_admin!` in HR (members, clients, projects, holidays, feedback meetings, workspace settings, the four HR reports) | `workspace_admin` |
| `require_employee!` | `time_hr_access` |
| `require_product!(:time_hr)` | `time_hr_access` |
| `require_product!(:workshop)` | at least one project membership |
| `require_client_or_employee!`, `require_workshop_member!` (Jira tasks, chat, breakdowns, drafts) | `require_permission!(:tasks)` |
| `require_admin!` in the Workshop (`WorkshopController`, brief commits, Jira sync and refresh, `update_jira`) | `require_permission!(:configuration)` |
| `require_workshop_config_access!` (Configuration, Discord webhooks) | `require_permission!(:configuration)` |
| Configuration's Briefing tab | `require_permission!(:briefing_config)` |
| Alert rules | `require_permission!(:automations)` |
| Workshop reports | `require_permission!(:reporting)` |
| `can_see_money?` in Workshop reports | `require_permission!(:pricing)` |
| `can_see_money?` in the HR detailed report | `workspace_admin` |

`visible_jira_projects` and `workshop_projects` both become "projects where the
user has a membership granting `tasks`", with workspace admins seeing all.

One endpoint belongs to neither product and needs saying out loud: the task
picker in the timer bar. Choosing which ticket you are logging hours against is
an HR action reading Jira's data, so it is gated on `time_hr_access` or any
project membership, and scoped to `available_projects` — the projects the
person is on — rather than to the Workshop's `tasks` permission. An employee
who tracks time but was never invited to the Workshop keeps their picker.

The two project scopes stay separate for the same reason. `available_projects`
answers "which projects may this person book time against" and reads any
membership. `visible_jira_projects` and `workshop_projects` answer "which
projects may this person work in" and require `tasks`.

`redirect_clients_to_jira`, the hard lock that pinned the `client` role to the
Jira Tasks path, is deleted. A person holding only `tasks` is refused
everything else by the ordinary gates, so the special case is no longer
earning its keep.

### The Configuration page

The page opens for anyone holding `configuration` or `briefing_config`; with
neither, it is refused entirely. Every tab then renders for anyone who got in. A tab the user lacks
permission for renders locked, with a padlock and an explanation on hover, and
is refused server-side as well. This follows the pattern the Users tab already
uses today for non-administrators.

A Product Owner therefore opens Configuration, sees four tabs, and can enter
only Briefing.

## Splitting HR from the Workshop

The two products stop sharing one membership record and one management screen.

- **The HR directory** lives in Workspace Settings. It manages who is an
  employee, their rates and their holidays, and is workspace admin only.
- **Workshop users** are managed per project, in Configuration › Users.
- Inviting someone to a project gives them no HR account. Adding an employee
  gives them no project.

The product switcher appears only when both are true: the person has
`time_hr_access` and at least one project membership. This is the requirement
that switching is possible only for an account that exists in both places,
expressed directly rather than through two flags that a form could set
inconsistently.

## Managing users in a project

Configuration › Users becomes a grid: the person, their derived role label, six
switches, and a control removing them from the project. The grid scrolls
horizontally inside its card rather than widening the page.

Two ways to add someone:

- **Add from other project** lists people who already have an account in
  another project of this workspace and adds the chosen ones with the defaults
  of the preset picked in the dialog.
- **Invite** takes a name and an email address. An unknown address creates the
  user and sends the existing invitation mail; a known one is added directly.

A workspace admin is always shown with every switch on, both switches and the
remove control disabled, because their access comes from the flag and not from
the membership row. Removing the row would change nothing, so offering it would
be a lie.

## Creating a project

The project switcher gains a `New project` entry, and each project in the list
shows its team and repository.

The dialog takes a name, an optional team and a repository, then for each of
Jira, GitHub, Discord, Figma and the AI provider offers either reusing the key
from a named existing project or setting it up later. Finally it offers people
from other projects as selectable chips.

**Keys are copied at creation, not linked.** Rotating a token therefore means
updating each project that holds it. The alternative, a reference to another
project's credentials, makes deleting a project a question about other
projects' keys and was rejected on that basis.

Creating a project switches to it and opens its Configuration.

## Backfill

The migration runs on MySQL in production, so the backfill is written in Ruby
rather than as a single `UPDATE`, and every column addition is guarded with
`column_exists?` so a half-applied migration can be re-run.

For each existing workspace membership:

| Today | Becomes |
| --- | --- |
| `admin`, `owner` | `workspace_admin`. No membership rows are created for them; rows they already have (carrying their hourly rate) get all six switches set, so the grid reads true |
| `employee` with `workshop_access` | Project Manager preset on each project they already belong to |
| `employee` without `workshop_access` | no project memberships, HR only |
| `workspace_client` | Product Owner preset on each project they already belong to |
| `client` | `tasks` only, on each project they already belong to, and `time_hr_access` forced off |

`time_hr_access` is otherwise carried over unchanged.

**A consequence worth stating.** A `workspace_client` can see money today.
The Product Owner preset has Pricing off, so after the migration they lose the
priced view until an administrator turns that one switch on. This follows from
the decision to map them to Product Owner and is reversible in the interface.

Workspace-level configuration is copied down to every project in the workspace,
so no project starts blank.

## Testing

- `PermissionPreset` label derivation, including the `Custom` fallback and the
  fact that it is order-independent.
- `ProjectAccess`: a workspace admin holds everything without a membership row;
  a member holds exactly their switches; a non-member holds nothing.
- One request test per gate family, asserting both the pass and the refusal:
  tasks, automations, reporting, pricing, briefing configuration,
  configuration, workspace admin, HR.
- The Configuration page renders locked tabs for a Product Owner and refuses
  them server-side.
- Project visibility: a member sees their projects, a workspace admin sees all.
- The product switcher appears only with both accesses, and neither invite path
  grants the other product.
- The backfill, run against fixtures covering all five old roles.
- The five existing test files that encode the old role model are rewritten:
  `client_access_test`, `client_role_test`, `product_access_test`,
  `workspace_client_time_hr_test`, `user_test`.

The local `pg` gem segfaults on the full suite, so files are run individually
locally and the whole suite is verified on the server.

## Rollout

Two deploys. The first adds columns, backfills and starts writing both the old
and the new model. The second removes `role`, `workshop_access` and the
workspace configuration columns once the new model is confirmed in production.
MySQL commits DDL outside the migration transaction, so a failure part-way
leaves columns behind; the guards above make the re-run safe.

## Out of scope

- Changing how the HR product works internally beyond the gate rename.
- Per-project holiday or timesheet scoping.
- Sharing one credential across projects by reference.
- Any change to how the Claude CLI is invoked, beyond reading the key from the
  project.
