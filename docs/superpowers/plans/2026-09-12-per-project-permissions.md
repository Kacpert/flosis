# Per-Project Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single workspace-wide role with six per-project permission switches, move integration and AI configuration onto the project, add project creation, and separate the HR employee directory from Workshop project membership.

**Architecture:** `project_memberships` becomes the record of what a person may do in a project, carrying six booleans. `workspace_memberships` shrinks to one global privilege plus HR access. A new `ProjectAccess` value object answers every authorization question, and the existing gate method names keep their names with new bodies, so the twenty HR controllers need no edits at all. Role names are derived from the granted set by `PermissionPreset` and never stored.

**Tech Stack:** Rails 8.1, Ruby 3.4.1, Minitest, Turbo/Stimulus, Tailwind v4, Capistrano. PostgreSQL in development and test, **MySQL in production**.

**Spec:** `docs/superpowers/specs/2026-09-12-per-project-permissions-design.md`

## Global Constraints

- **Production is MySQL.** Raw SQL and migrations must run there. No `NULLS LAST`, no `UPDATE ... FROM (SELECT ROW_NUMBER())`, no `ILIKE`. Write backfills in Ruby.
- **MySQL commits DDL outside the migration transaction.** A failure part-way leaves columns behind, so guard every `add_column` with `column_exists?` and every `add_index` with `index_exists?`.
- **The local `pg` gem segfaults on the full suite.** Run test files individually locally; verify the whole suite on the server.
- **Commit messages carry no `Co-Authored-By` and no `Claude-Session` trailer.** The `production` branch history was deliberately purged of them.
- **`%w[]` arrays take no comments.** A `#` line inside one becomes a literal entry. Put prose above the literal.
- Permission order everywhere in the interface: Automations, Tasks, Reporting, Pricing, Briefing Configuration, Configuration. Briefing Configuration always precedes Configuration.
- Preset labels are exactly `Project Manager`, `Product Owner`, `Administrator`, `Custom`.
- Deploy in two releases. Tasks 1 through 17 and Task 19 are release one, in that order — 19 explains the permissions and needs the screens from 14 and 15 to exist first. Task 18 is release two and only runs after release one is confirmed in production.

---

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `app/models/permission_preset.rb` | The six permission names, the preset table, and label derivation. Pure Ruby, no database. |
| `app/services/project_access.rb` | Answers `can?(permission)` for a user and a project. The only place authorization is decided. |
| `app/services/project_creator.rb` | Creates a project, copies chosen credentials from a source project, adds chosen members with a preset. |
| `app/views/workshop/configuration/_user_row.html.erb` | One row of the Users grid. |
| `app/views/workshop/configuration/_invite_modal.html.erb` | Invite and Add-from-other-project dialogs. |
| `app/views/layouts/_clar_new_project_modal.html.erb` | The New project dialog. |
| `app/javascript/controllers/permission_switch_controller.js` | Posts a switch change and updates the derived role label without a reload. |
| `app/javascript/controllers/preset_picker_controller.js` | Role preset buttons set the switches in the invite dialog. |
| `app/views/workshop/configuration/_permission_legend.html.erb` | What each of the six permissions allows, and what the three preset names add up to. No locals. |
| `app/views/profiles/_access_card.html.erb` | A person's own access, per project, in the HR design system. |
| `app/models/concerns/estimation_settings.rb` | The AI estimation settings and their MySQL-safe normalization, shared while both the workspace and the project carry the columns. |
| `app/controllers/workshop/projects_controller.rb` | Creates a project from the switcher's dialog. Workshop-side, so it needs no HR account. |

**Modified files, grouped by what they are responsible for**

- Authorization: `app/controllers/concerns/authorization.rb`, `app/controllers/concerns/workspace_scoped.rb`, `app/models/user.rb`, `app/models/workspace_membership.rb`, `app/models/project_membership.rb`.
- Workshop gates: `app/controllers/workshop/*.rb`, `app/controllers/jira_tasks_controller.rb`, `app/controllers/jira_controller.rb`, `app/controllers/chat_sessions_controller.rb`, `app/controllers/brief_chat_sessions_controller.rb`, `app/controllers/breakdown_chat_sessions_controller.rb`, `app/controllers/brief_commits_controller.rb`, `app/controllers/task_breakdowns_controller.rb`, `app/controllers/task_drafts_controller.rb`, `app/controllers/workshop_controller.rb`.
- Credentials: `app/services/project_credentials.rb`, `app/services/project_mcp_config.rb`, `app/services/figma_client.rb`, `app/services/github_client.rb`, `app/jobs/integration_health_job.rb`, `app/jobs/pr_review_job.rb`, `app/jobs/pr_review_check_job.rb`.
- The AI jobs' working directory: `app/jobs/alert_rule_run_job.rb`, `app/jobs/bug_attribution_job.rb`, `app/jobs/auto_estimate_job.rb`, `app/jobs/backfill_delivered_estimates_job.rb` — each drops its own `CODEBASE_PATH` for the checkout of the project it was handed (Task 11c).
- Explaining the permissions: `app/models/permission_preset.rb` gains `LABELS` and `DESCRIPTIONS`, and they are the only source of that copy anywhere in the product (Task 14 Step 0).
- Views: `app/views/workshop/configuration/*`, `app/views/layouts/_clar_topbar.html.erb`, `app/views/layouts/_clar_sidebar.html.erb`, `app/views/workshop/reports/_metrics.html.erb`, `app/views/workshop/reports/_dev_table.html.erb`, `app/views/profiles/show.html.erb`, `app/views/workshop/process/_estimate_tab.html.erb`, `app/helpers/clar_helper.rb`.

**HR controllers are deliberately not in this list.** `require_admin!`, `require_employee!` and `require_product!` keep their names and gain new bodies, so `holiday_requests_controller.rb`, `timesheets_controller.rb`, `clients_controller.rb`, `projects_controller.rb` (HR's — the Workshop gets its own in Task 17), `workspace_members_controller.rb`, `feedback_meetings_controller.rb`, `tags_controller.rb`, `timers_controller.rb`, `time_entries_controller.rb`, `holiday_balance_entries_controller.rb`, `project_memberships_controller.rb`, `workspace_settings_controller.rb`, `discord_reminder_recipients_controller.rb` and the four `reports/*` controllers are untouched.

---

## Phase A — the permission model

### Task 1: PermissionPreset

**Files:**
- Create: `app/models/permission_preset.rb`
- Test: `test/models/permission_preset_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `PermissionPreset::PERMISSIONS` (frozen `Array<Symbol>`, interface order), `PermissionPreset::PRESETS` (frozen `Hash{String => Array<Symbol>}`), `PermissionPreset.label_for(granted) -> String`, `PermissionPreset.attributes_for(label) -> Hash{Symbol => Boolean}` covering all six keys.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/permission_preset_test.rb
require "test_helper"

# A role is a name read off the switches, never a stored value. These pin the
# derivation down, including the case that matters most: a set matching no
# preset is "Custom", which is a normal state and not an error.
class PermissionPresetTest < ActiveSupport::TestCase
  test "names the three presets" do
    assert_equal "Project Manager", PermissionPreset.label_for(%i[automations tasks reporting])
    assert_equal "Product Owner", PermissionPreset.label_for(%i[automations tasks reporting briefing_config])
    assert_equal "Administrator", PermissionPreset.label_for(PermissionPreset::PERMISSIONS)
  end

  test "the label does not depend on the order it is given" do
    assert_equal "Product Owner", PermissionPreset.label_for(%i[briefing_config reporting tasks automations])
  end

  test "the label accepts strings as well as symbols" do
    assert_equal "Project Manager", PermissionPreset.label_for(%w[automations tasks reporting])
  end

  test "anything else is Custom, including nothing at all" do
    assert_equal "Custom", PermissionPreset.label_for(%i[tasks])
    assert_equal "Custom", PermissionPreset.label_for([])
    assert_equal "Custom", PermissionPreset.label_for(%i[automations tasks reporting pricing])
  end

  test "Briefing Configuration precedes Configuration in the interface order" do
    order = PermissionPreset::PERMISSIONS
    assert order.index(:briefing_config) < order.index(:configuration)
  end

  test "attributes_for turns a preset into every switch, on or off" do
    attrs = PermissionPreset.attributes_for("Product Owner")

    assert_equal PermissionPreset::PERMISSIONS.sort, attrs.keys.sort
    assert attrs[:briefing_config]
    assert_not attrs[:configuration]
    assert_not attrs[:pricing], "Pricing is off by default for everyone but an Administrator"
  end

  test "an unknown preset falls back to the least privileged one" do
    assert_equal PermissionPreset.attributes_for("Project Manager"),
                 PermissionPreset.attributes_for("Wizard")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/permission_preset_test.rb`
Expected: FAIL with `NameError: uninitialized constant PermissionPreset`

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/models/permission_preset.rb

# The six things a person can be allowed to do inside a project, plus the
# handful of named combinations worth a button in the invite dialog.
#
# A role is NOT stored anywhere. The switches are the truth and the name is
# read back off them, so flipping one switch simply moves the label — possibly
# to "Custom", which is a legitimate state rather than an error.
module PermissionPreset
  # Interface order, used by every view that renders the switches. Briefing
  # Configuration precedes Configuration.
  PERMISSIONS = %i[automations tasks reporting pricing briefing_config configuration].freeze

  # Pricing is deliberately off by default. Reporting is on by default, so
  # folding the two together would show every Project Manager the team's rates.
  PRESETS = {
    "Project Manager" => %i[automations tasks reporting].freeze,
    "Product Owner" => %i[automations tasks reporting briefing_config].freeze,
    "Administrator" => PERMISSIONS
  }.freeze

  CUSTOM = "Custom".freeze
  LEAST_PRIVILEGED = "Project Manager".freeze

  # The name for a granted set, or "Custom" when it matches no preset. Callers
  # pass whatever order and type they happen to have.
  def self.label_for(granted)
    wanted = Array(granted).map(&:to_sym).uniq.sort
    PRESETS.each { |label, permissions| return label if permissions.sort == wanted }
    CUSTOM
  end

  # A preset as a full hash of switches, ready for assign_attributes. Every one
  # of the six keys is present, so applying a preset also turns things OFF.
  def self.attributes_for(label)
    permissions = PRESETS.fetch(label.to_s, PRESETS[LEAST_PRIVILEGED])
    PERMISSIONS.index_with { |permission| permissions.include?(permission) }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/permission_preset_test.rb`
Expected: PASS, 7 runs

- [ ] **Step 6: Commit**

```bash
git add app/models/permission_preset.rb test/models/permission_preset_test.rb
git commit -m "feat: permission presets, with the role name derived from the switches"
```

---

### Task 2: The permission columns

**Files:**
- Create: `db/migrate/20260912120000_add_per_project_permissions.rb`
- Modify: `app/models/project_membership.rb`, `app/models/workspace_membership.rb`
- Test: `test/models/project_membership_permissions_test.rb`

**Interfaces:**
- Consumes: `PermissionPreset` from Task 1.
- Produces: six boolean columns on `project_memberships` (`automations`, `tasks`, `reporting`, `pricing`, `briefing_config`, `configuration`); `workspace_admin` boolean on `workspace_memberships`; `ProjectMembership#granted -> Array<Symbol>`, `#role_label -> String`, `#apply_preset(label) -> self`; `WorkspaceMembership#workspace_admin` accessor.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/project_membership_permissions_test.rb
require "test_helper"

# project_memberships already recorded that a person is on a project, with
# their rate. It now also records what they may do there, which keeps one row
# per person per project instead of inventing a parallel table.
class ProjectMembershipPermissionsTest < ActiveSupport::TestCase
  setup { @membership = project_memberships(:two_elvium) }

  test "a new membership starts on the invite defaults" do
    fresh = ProjectMembership.new

    assert fresh.automations
    assert fresh.tasks
    assert fresh.reporting
    assert_not fresh.pricing
    assert_not fresh.briefing_config
    assert_not fresh.configuration
  end

  test "granted lists the switches that are on, in interface order" do
    @membership.update!(PermissionPreset.attributes_for("Product Owner"))

    assert_equal %i[automations tasks reporting briefing_config], @membership.granted
  end

  test "the role label is read off the switches" do
    @membership.update!(PermissionPreset.attributes_for("Project Manager"))
    assert_equal "Project Manager", @membership.role_label

    @membership.update!(briefing_config: true)
    assert_equal "Product Owner", @membership.role_label

    @membership.update!(pricing: true)
    assert_equal "Custom", @membership.role_label
  end

  test "applying a preset turns switches off as well as on" do
    @membership.update!(PermissionPreset.attributes_for("Administrator"))

    @membership.apply_preset("Project Manager")

    assert_not @membership.configuration, "the preset must clear what it does not grant"
    assert_not @membership.pricing
    assert @membership.tasks
  end

  test "a workspace membership is not an admin until it is told to be" do
    assert_not workspace_memberships(:two_employee).workspace_admin
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/project_membership_permissions_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'automations'`

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260912120000_add_per_project_permissions.rb

# Six switches per person per project, plus the one global privilege that
# survives the old five-value role enum.
#
# Guarded column by column: MySQL commits DDL outside the migration
# transaction, so a failure part-way leaves the earlier columns behind and the
# re-run must not trip over them.
class AddPerProjectPermissions < ActiveRecord::Migration[8.1]
  COLUMNS = {
    automations: true,
    tasks: true,
    reporting: true,
    pricing: false,
    briefing_config: false,
    configuration: false
  }.freeze

  def up
    COLUMNS.each do |name, default|
      next if column_exists?(:project_memberships, name)
      add_column :project_memberships, name, :boolean, default: default, null: false
    end

    unless column_exists?(:workspace_memberships, :workspace_admin)
      add_column :workspace_memberships, :workspace_admin, :boolean, default: false, null: false
    end
  end

  def down
    COLUMNS.each_key do |name|
      remove_column :project_memberships, name if column_exists?(:project_memberships, name)
    end
    if column_exists?(:workspace_memberships, :workspace_admin)
      remove_column :workspace_memberships, :workspace_admin
    end
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `bin/rails db:migrate`
Expected: the six columns plus `workspace_admin` appear in `db/schema.rb`

- [ ] **Step 5: Add the model methods**

```ruby
# app/models/project_membership.rb — add below the validations

  # What this person may do in this project. The switches are the truth; the
  # role name is derived from them (see PermissionPreset).
  PERMISSIONS = PermissionPreset::PERMISSIONS

  # The switches that are on, in interface order.
  def granted
    PERMISSIONS.select { |permission| self[permission] }
  end

  def role_label
    PermissionPreset.label_for(granted)
  end

  # Applies a named preset. Deliberately assigns ALL six switches, so this
  # clears what the preset does not grant rather than only adding to it.
  def apply_preset(label)
    assign_attributes(PermissionPreset.attributes_for(label))
    self
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/models/project_membership_permissions_test.rb`
Expected: PASS, 5 runs

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260912120000_add_per_project_permissions.rb db/schema.rb \
  app/models/project_membership.rb test/models/project_membership_permissions_test.rb
git commit -m "feat: per-project permission switches on project memberships"
```

---

### Task 3: ProjectAccess

**Files:**
- Create: `app/services/project_access.rb`
- Modify: `app/models/user.rb`, `app/models/workspace_membership.rb`
- Test: `test/services/project_access_test.rb`

**Interfaces:**
- Consumes: `PermissionPreset`, the columns from Task 2.
- Produces: `ProjectAccess.new(user, project)` with `#can?(permission) -> Boolean`, `#member? -> Boolean`, `#workspace_admin? -> Boolean`, `#granted -> Array<Symbol>`, `#role_label -> String`; `User#workspace_admin?(workspace) -> Boolean`; `User#project_access(project) -> ProjectAccess`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/project_access_test.rb
require "test_helper"

# One object answers every authorization question, because the alternative —
# six predicates on User, each with its own idea of who counts — is what this
# work is replacing.
class ProjectAccessTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @other_project = projects(:other_jira_project)
    @member = users(:two)
    @admin = users(:one)
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Project Manager"))
  end

  test "a member holds exactly their switches" do
    access = ProjectAccess.new(@member, @project)

    assert access.can?(:tasks)
    assert access.can?(:automations)
    assert_not access.can?(:configuration)
    assert_not access.can?(:pricing)
  end

  test "a non-member holds nothing" do
    access = ProjectAccess.new(@member, @other_project)

    assert_not access.member?
    PermissionPreset::PERMISSIONS.each { |p| assert_not access.can?(p), "expected no #{p}" }
  end

  test "a workspace admin holds everything, with no membership row at all" do
    assert_nil ProjectMembership.find_by(user: @admin, project: @other_project)
    access = ProjectAccess.new(@admin, @other_project)

    assert access.member?
    PermissionPreset::PERMISSIONS.each { |p| assert access.can?(p), "expected #{p}" }
    assert_equal "Administrator", access.role_label
  end

  test "an unknown permission is refused rather than raising" do
    assert_not ProjectAccess.new(@member, @project).can?(:launch_missiles)
  end

  test "a nil user or a nil project holds nothing" do
    assert_not ProjectAccess.new(nil, @project).can?(:tasks)
    assert_not ProjectAccess.new(@member, nil).can?(:tasks)
  end

  test "the role label of a member is read off their switches" do
    assert_equal "Project Manager", ProjectAccess.new(@member, @project).role_label
  end

  test "User#project_access hands back an access object for that project" do
    assert @member.project_access(@project).can?(:tasks)
    assert_not @member.project_access(@other_project).can?(:tasks)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/project_access_test.rb`
Expected: FAIL with `NameError: uninitialized constant ProjectAccess`

- [ ] **Step 3: Write the implementation**

```ruby
# app/services/project_access.rb

# "May this person do this in this project?" — the single place that answers it.
#
# Access has exactly two sources. A workspace admin holds everything in every
# project WITHOUT a membership row: the privilege is global, and deleting a row
# must never be able to lock the workspace away from its own administrator.
# Everyone else holds precisely the switches on their row, and nothing at all
# without one.
class ProjectAccess
  def initialize(user, project)
    @user = user
    @project = project
  end

  def workspace_admin?
    return false unless @user && @project&.workspace

    @user.workspace_admin?(@project.workspace)
  end

  # On the project at all — either by the global privilege or by a row.
  def member?
    workspace_admin? || membership.present?
  end

  def can?(permission)
    name = permission.to_sym
    return false unless PermissionPreset::PERMISSIONS.include?(name)
    return true if workspace_admin?

    membership.present? && membership[name]
  end

  # The switches actually held. A workspace admin reads as all six, which is
  # what the Users grid has to show for them.
  def granted
    return PermissionPreset::PERMISSIONS if workspace_admin?

    membership&.granted || []
  end

  def role_label
    PermissionPreset.label_for(granted)
  end

  private

  # Memoised with defined? rather than ||=, so "no row" is looked up once
  # instead of on every question asked of this object.
  def membership
    return @membership if defined?(@membership)

    @membership = if @user && @project
      ProjectMembership.find_by(user_id: @user.id, project_id: @project.id)
    end
  end
end
```

- [ ] **Step 4: Add the User entry points**

```ruby
# app/models/user.rb — add near the other membership helpers

  def workspace_admin?(workspace)
    membership_for(workspace)&.workspace_admin || false
  end

  # The entry point for every authorization question about a project.
  def project_access(project)
    ProjectAccess.new(self, project)
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/services/project_access_test.rb`
Expected: PASS, 7 runs

- [ ] **Step 6: Commit**

```bash
git add app/services/project_access.rb app/models/user.rb test/services/project_access_test.rb
git commit -m "feat: ProjectAccess answers every per-project permission question"
```

---

### Task 4: Backfill the existing roles

**Files:**
- Create: `db/migrate/20260912121000_backfill_per_project_permissions.rb`
- Test: `test/migrations/backfill_per_project_permissions_test.rb`

**Interfaces:**
- Consumes: Tasks 1 through 3.
- Produces: every existing membership carrying equivalent permissions. Nothing later in the plan depends on this class by name.

**Mapping.** Administrator and owner become workspace admins and get no new rows; rows they already have (which carry their hourly rate) get all six switches, so the grid reads true. An employee with Workshop access gets the Project Manager preset on the projects they already belong to. An employee without it gets nothing and stays HR-only. A `workspace_client` becomes a Product Owner. A `client` keeps only Tasks and loses HR access.

**Known consequence:** a `workspace_client` can see money today and the Product Owner preset has Pricing off, so after this runs they lose the priced view until an administrator turns that one switch on. This is intended and will be done by hand after the deploy.

- [ ] **Step 1: Write the failing test**

```ruby
# test/migrations/backfill_per_project_permissions_test.rb
require "test_helper"
require Rails.root.join("db/migrate/20260912121000_backfill_per_project_permissions")

# The backfill is the only part of this work that touches live data, so it gets
# a test rather than a careful read. Deleted in Task 18 along with the columns
# it reads.
class BackfillPerProjectPermissionsTest < ActiveSupport::TestCase
  # The `two_employee` fixture ships with `workshop_access: false`. Most cases
  # here want the employee who DID have Workshop access, so turn it on in setup
  # and let the one case that tests the other branch turn it back off.
  setup do
    workspace_memberships(:two_employee).update_columns(workshop_access: true)
    ProjectMembership.update_all(PermissionPreset::PERMISSIONS.index_with(false))
    WorkspaceMembership.update_all(workspace_admin: false)
    BackfillPerProjectPermissions.new.up
  end

  test "an owner becomes a workspace admin and gains no new rows" do
    assert workspace_memberships(:one_owner).reload.workspace_admin
    assert_nil ProjectMembership.find_by(user: users(:one), project: projects(:other_jira_project))
  end

  test "an owner's existing rows read as Administrator" do
    assert_equal "Administrator", project_memberships(:one_elvium).reload.role_label
  end

  test "an employee with Workshop access becomes a Project Manager" do
    assert_equal "Project Manager", project_memberships(:two_elvium).reload.role_label
  end

  test "an employee without Workshop access gets no permissions" do
    workspace_memberships(:two_employee).update_columns(workshop_access: false)
    ProjectMembership.update_all(PermissionPreset::PERMISSIONS.index_with(false))
    WorkspaceMembership.update_all(workspace_admin: false)

    BackfillPerProjectPermissions.new.up

    assert_equal [], project_memberships(:two_elvium).reload.granted
  end

  test "a workspace_client becomes a Product Owner" do
    assert_equal "Product Owner", project_memberships(:workspace_client_elvium).reload.role_label
  end

  test "a client keeps Tasks only and loses HR" do
    membership = project_memberships(:client_elvium).reload

    assert_equal %i[tasks], membership.granted
    assert_not workspace_memberships(:client_membership).reload.time_hr_access
  end

  test "running it twice changes nothing" do
    before = ProjectMembership.order(:id).pluck(:id, *PermissionPreset::PERMISSIONS)

    BackfillPerProjectPermissions.new.up

    assert_equal before, ProjectMembership.order(:id).pluck(:id, *PermissionPreset::PERMISSIONS)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/migrations/backfill_per_project_permissions_test.rb`
Expected: FAIL with `LoadError` — the migration file does not exist

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260912121000_backfill_per_project_permissions.rb

# Translates the old five-value role into the new switches.
#
# Written in Ruby, not SQL: production is MySQL and the row-by-row shape is the
# same either way, so there is nothing to gain from a clever UPDATE that then
# has to be written twice.
class BackfillPerProjectPermissions < ActiveRecord::Migration[8.1]
  # The old enum, by the integer actually stored in the column. Read by value
  # because the enum itself is removed from the model in this same release.
  EMPLOYEE = 0
  ADMIN = 1
  OWNER = 2
  CLIENT = 3
  WORKSPACE_CLIENT = 4

  def up
    WorkspaceMembership.reset_column_information
    ProjectMembership.reset_column_information

    say_with_time "translating roles into per-project permissions" do
      WorkspaceMembership.find_each do |membership|
        case membership.read_attribute(:role)
        when ADMIN, OWNER then promote_to_workspace_admin(membership)
        when CLIENT then grant(membership, %i[tasks], revoke_hr: true)
        when WORKSPACE_CLIENT then grant(membership, PermissionPreset::PRESETS.fetch("Product Owner"))
        else grant(membership, employee_permissions(membership))
        end
      end
    end
  end

  # Release one keeps the old columns, so there is nothing to restore.
  def down; end

  private

  def employee_permissions(membership)
    return [] unless membership.read_attribute(:workshop_access)

    PermissionPreset::PRESETS.fetch("Project Manager")
  end

  # No rows are created for an admin — their access is the flag. Rows they
  # already have get every switch on so the Users grid does not lie.
  def promote_to_workspace_admin(membership)
    membership.update_columns(workspace_admin: true)
    rows_for(membership).update_all(PermissionPreset::PERMISSIONS.index_with(true))
  end

  def grant(membership, permissions, revoke_hr: false)
    membership.update_columns(workspace_admin: false)
    membership.update_columns(time_hr_access: false) if revoke_hr
    rows_for(membership).update_all(
      PermissionPreset::PERMISSIONS.index_with { |permission| permissions.include?(permission) }
    )
  end

  def rows_for(membership)
    ProjectMembership.where(
      user_id: membership.user_id,
      project_id: Project.where(workspace_id: membership.workspace_id).select(:id)
    )
  end
end
```

- [ ] **Step 4: Run it and verify the test passes**

Run: `bin/rails db:migrate && bin/rails test test/migrations/backfill_per_project_permissions_test.rb`
Expected: PASS, 7 runs

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260912121000_backfill_per_project_permissions.rb db/schema.rb \
  test/migrations/backfill_per_project_permissions_test.rb
git commit -m "feat: translate the old workspace roles into per-project permissions"
```

---

## Phase B — the authorization cutover

### Task 5: Rewrite the gates

**Files:**
- Modify: `app/controllers/concerns/authorization.rb`, `app/controllers/concerns/workspace_scoped.rb`, `app/models/user.rb`, `app/models/workspace_membership.rb`
- Test: `test/models/product_access_test.rb` (rewritten), `test/controllers/permission_gates_test.rb` (new)

**Interfaces:**
- Consumes: `ProjectAccess`, `PermissionPreset`.
- Produces: controller helpers `current_project_access -> ProjectAccess`, `can?(permission) -> Boolean`, `workspace_admin? -> Boolean`; gates `require_permission!(permission)`, `require_admin!`, `require_employee!`, `require_time_hr_or_project_member!`; `User#can_access_workshop?(workspace)` now meaning "has at least one project".

**The names `require_admin!`, `require_employee!` and `require_product!` are kept on purpose.** Seventeen HR controllers already call them, and keeping the names means only the bodies in this concern change.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/permission_gates_test.rb
require "test_helper"

# One request per gate family, asserting the refusal as well as the pass.
# Sixty files used to decide access for themselves; these pin down the handful
# of gates that now decide it for them.
class PermissionGatesTest < ActionDispatch::IntegrationTest
  setup do
    @project = projects(:jira_project)
    @user = users(:two)
    workspace_memberships(:two_employee).update!(workspace_admin: false, time_hr_access: true)
    @membership = project_memberships(:two_elvium)
    sign_in_as(@user)
  end

  def with_permissions(preset)
    @membership.update!(PermissionPreset.attributes_for(preset))
  end

  # The Workshop-route cases live in Task 6 and the Configuration-tab cases in
  # Task 8 — each is added by the task that makes it pass, so no task commits a
  # red test.

  test "the workspace privilege opens the HR member directory" do
    with_permissions("Project Manager")
    get workspace_members_path
    assert_redirected_to root_path

    workspace_memberships(:two_employee).update!(workspace_admin: true)
    get workspace_members_path
    assert_response :success
  end

  test "HR access alone opens the timesheet" do
    with_permissions("Project Manager")
    get timesheets_path
    assert_response :success

    workspace_memberships(:two_employee).update!(time_hr_access: false)
    get timesheets_path
    assert_response :redirect
  end

end
```

The timer-picker case lives in Task 6, which is where `JiraController` gets the scope change that makes it pass.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/permission_gates_test.rb`
Expected: FAIL — the Product Owner cases pass the page today, since Configuration is one admin-only gate

- [ ] **Step 3: Add the new gates to the Authorization concern**

**Add these to `app/controllers/concerns/authorization.rb`, leaving everything already there in place.** The old predicates are still called by fourteen Workshop controllers and a dozen views, which Tasks 6 to 8 migrate one at a time; deleting them here would leave three tasks committing a tree that raises. Task 9 removes them in one sweep once the last caller is gone.

Extend the existing `helper_method` list rather than replacing it, and add the methods below. **Everything shown here is new except `require_admin!`, `require_employee!` and `visible_jira_projects`, which replace same-named methods already in the file.** Do not re-declare `current_membership`, `deny_access!`, `require_product!` or `jira_record_not_found` — they are already there and unchanged.

```ruby
# Every authorization question in the app funnels through here.
#
# There are now exactly two kinds of question. "May this person do X in THIS
# project?" goes to ProjectAccess. "Is this person the workspace's
# administrator?" reads one flag. The six User predicates that used to answer
# variations on both are gone.
#
# require_admin!, require_employee! and require_product! keep their names
# because seventeen HR controllers call them; only the bodies changed.
module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :current_project_access, :can?,
                  :workspace_admin?, :visible_jira_projects, :github_connection_problem?
  end

  private

  def workspace_admin?
    current_user&.workspace_admin?(current_workspace) || false
  end

  # Access to the Workshop project currently being viewed.
  def current_project_access
    @current_project_access ||= ProjectAccess.new(current_user, current_workshop_project)
  end

  def can?(permission)
    current_project_access.can?(permission)
  end

  def require_permission!(permission)
    return if can?(permission)

    deny_access!("You don't have permission to access this page.", product_landing_path)
  end

  # The workspace-wide privilege: creating projects, the HR module, the
  # employee directory.
  def require_admin!
    return if workspace_admin?

    deny_access!("You don't have permission to access this page.", root_path)
  end

  # The HR working surfaces: time entries, timesheet, timer, tags, holidays.
  def require_employee!
    return if current_user&.can_access_time_hr?(current_workspace)

    deny_access!("You don't have permission to access this page.", root_path)
  end

  # The timer bar's Jira task picker belongs to neither product. Choosing which
  # ticket you are logging hours against is an HR action that happens to read
  # Jira's data, so an employee who was never invited to the Workshop must keep
  # it. The real boundary stays available_projects: you only ever see the
  # projects you are on.
  def require_time_hr_or_project_member!
    return if current_user&.can_access_time_hr?(current_workspace)
    return if available_projects.exists?

    deny_access!("You don't have permission to access this page.", root_path)
  end

  # Jira projects the user may WORK in. Admins see every one; everyone else
  # sees the projects where their membership grants Tasks.
  def visible_jira_projects
    scope = current_workspace.projects.active.where(external_type: "jira")
    return scope.order(:name) if workspace_admin?

    scope.joins(:project_memberships)
         .where(project_memberships: { user_id: current_user&.id, tasks: true })
         .order(:name)
  end

end
```

`deny_access!`, `current_membership`, `require_product!` and `jira_record_not_found` already exist and are unchanged. `github_connection_problem?` keeps reading the workspace for now — the project's own `github_status_ok` column does not exist until Task 10, and Task 11 is where it moves.

**Replace** the existing `require_admin!`, `require_employee!` and `visible_jira_projects` with the versions above; that is the whole of this task's destructive surface.

- [ ] **Step 4: Rewrite the product predicates on User**

In `app/models/user.rb`, **leave every existing predicate in place** — Task 9 deletes them once the last caller is gone. Replace only the product block (`can_access_time_hr?`, `can_access_workshop?`, `accessible_products`, `default_product`, `can_access_product?`) with:

```ruby
  # ---- Product access (Time & HR / Workshop) ---------------------------
  # The app is two products sharing one database. HR access is a flag on the
  # workspace membership. Workshop access is having somewhere to work: at least
  # one project. Keeping them on different facts is what makes the product
  # switcher honest — it appears exactly when an account exists in both places,
  # rather than when two checkboxes on one form happen to agree.

  def can_access_time_hr?(workspace)
    membership_for(workspace)&.time_hr_access || false
  end

  def can_access_workshop?(workspace)
    return false unless workspace
    return true if workspace_admin?(workspace)

    project_memberships.joins(:project)
                       .where(projects: { workspace_id: workspace.id, archived: false })
                       .exists?
  end

  # Order matters: the first entry is the default landing product. The host
  # still overrides it, which is how app.flosis.com lands on the Workshop.
  def accessible_products(workspace)
    products = []
    products << :time_hr if can_access_time_hr?(workspace)
    products << :workshop if can_access_workshop?(workspace)
    products
  end

  def default_product(workspace)
    accessible_products(workspace).first
  end

  def can_access_product?(workspace, product)
    accessible_products(workspace).include?(product.to_sym)
  end
```

- [ ] **Step 5: Collapse the duplicated project scope, and check the fallout**

In `app/controllers/concerns/workspace_scoped.rb`, replace `workshop_projects` with a delegation, removing the duplicated scope:

```ruby
  # The Jira projects forming the Workshop work context — the same set
  # Authorization already scopes for the Jira board.
  def workshop_projects
    visible_jira_projects
  end
```

Leave `redirect_clients_to_jira`, its constants and `product_landing_path` alone; they still read `client_role?`, which survives until Task 9.

**This task changes one behaviour, so check what it moves.** Workshop access used to be a flag and is now "has at least one project". A fixture employee with `workshop_access: false` who nevertheless has a project membership now HAS Workshop access. Run `bin/rails test test/controllers/workshop_controller_test.rb` and fix any case that was relying on the old flag by giving or removing the project membership, not by reintroducing the flag.

- [ ] **Step 6: Rewrite the product access test**

Replace `test/models/product_access_test.rb` with:

```ruby
require "test_helper"

# The product switcher must mean what it says: you can move between HR and the
# Workshop only when your account exists in both. Two flags on one form could
# disagree; two different facts cannot.
class ProductAccessTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @user = users(:two)
    @membership = workspace_memberships(:two_employee)
  end

  test "HR access is the flag on the workspace membership" do
    @membership.update!(time_hr_access: true)
    assert @user.can_access_time_hr?(@workspace)

    @membership.update!(time_hr_access: false)
    assert_not @user.can_access_time_hr?(@workspace)
  end

  test "Workshop access is having at least one project" do
    assert @user.can_access_workshop?(@workspace)

    ProjectMembership.where(user: @user).destroy_all
    assert_not @user.reload.can_access_workshop?(@workspace)
  end

  test "an archived project is not somewhere to work" do
    ProjectMembership.where(user: @user).where.not(project: projects(:jira_project)).destroy_all
    projects(:jira_project).update!(archived: true)

    assert_not @user.reload.can_access_workshop?(@workspace)
  end

  test "a workspace admin always has the Workshop, with no project rows" do
    ProjectMembership.where(user: @user).destroy_all
    @membership.update!(workspace_admin: true)

    assert @user.reload.can_access_workshop?(@workspace)
  end

  test "both accesses means both products" do
    @membership.update!(time_hr_access: true)

    assert_equal %i[time_hr workshop], @user.accessible_products(@workspace)
  end

  test "one access means one product, and it is the default" do
    @membership.update!(time_hr_access: false)

    assert_equal %i[workshop], @user.accessible_products(@workspace)
    assert_equal :workshop, @user.default_product(@workspace)
  end
end
```

- [ ] **Step 7: Run both tests**

Run: `bin/rails test test/models/product_access_test.rb test/controllers/permission_gates_test.rb`
Expected: PASS. Tabs in Task 6 and 8 finish the Product Owner cases if they still fail here.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/concerns/authorization.rb app/controllers/concerns/workspace_scoped.rb \
  app/models/user.rb app/models/workspace_membership.rb \
  test/models/product_access_test.rb test/controllers/permission_gates_test.rb
git commit -m "feat: authorization asks ProjectAccess, and product access means having somewhere to work"
```

---

### Task 6: Point the Workshop controllers at the new gates

**Files:**
- Modify: `app/controllers/workshop/base_controller.rb`, `app/controllers/workshop/configuration_controller.rb`, `app/controllers/workshop/alert_rules_controller.rb`, `app/controllers/workshop/reports_controller.rb`, `app/controllers/workshop/discord_webhooks_controller.rb`, `app/controllers/workshop_controller.rb`, `app/controllers/jira_tasks_controller.rb`, `app/controllers/jira_controller.rb`, `app/controllers/chat_sessions_controller.rb`, `app/controllers/brief_chat_sessions_controller.rb`, `app/controllers/breakdown_chat_sessions_controller.rb`, `app/controllers/brief_commits_controller.rb`, `app/controllers/task_breakdowns_controller.rb`, `app/controllers/task_drafts_controller.rb`
- Test: `test/controllers/permission_gates_test.rb` (from Task 5)

**Interfaces:**
- Consumes: `require_permission!` from Task 5.
- Produces: no new interface. Every Workshop route is gated on one of the six permissions.

**The full mapping.** Apply each line exactly.

| File | Today | Becomes |
| --- | --- | --- |
| `workshop/base_controller.rb` | `require_product!(:workshop)` | unchanged, plus `require_permission!(:tasks)` for the whole subtree |
| `workshop/configuration_controller.rb` | `require_workshop_config_access!` + `block_admin_only_tabs` | per-tab, see Task 8 |
| `workshop/alert_rules_controller.rb` | inherited only | `before_action { require_permission!(:automations) }` |
| `workshop/reports_controller.rb` | inherited only | `before_action { require_permission!(:reporting) }` |
| `workshop/discord_webhooks_controller.rb` | `require_workshop_config_access!` | `require_permission!(:configuration)` |
| `workshop_controller.rb` | `require_admin!` | `require_permission!(:configuration)` |
| `jira_tasks_controller.rb` | `require_client_or_employee!`, `require_admin!` on `:refresh` | `require_permission!(:tasks)`, `require_permission!(:configuration)` on `:refresh` |
| `jira_controller.rb` | `require_admin!` on `:projects`/`:sync`, `require_workspace_member!` on `:jira_tasks` | `require_permission!(:configuration)`, `require_time_hr_or_project_member!` |
| `chat_sessions_controller.rb` | `require_client_or_employee!` | `require_permission!(:tasks)` |
| `brief_chat_sessions_controller.rb` | `require_workshop_member!` | `require_permission!(:tasks)` |
| `breakdown_chat_sessions_controller.rb` | `require_client_or_employee!` | `require_permission!(:tasks)` |
| `brief_commits_controller.rb` | `require_admin!` | `require_permission!(:configuration)` |
| `task_breakdowns_controller.rb` | `require_client_or_employee!`, `require_admin!` on `:update_jira` | `require_permission!(:tasks)`, `require_permission!(:configuration)` on `:update_jira` |
| `task_drafts_controller.rb` | `require_client_or_employee!` | `require_permission!(:tasks)` |

- [ ] **Step 1: Apply the base controller gate**

First add the membership gate to `app/controllers/concerns/authorization.rb`, beside `require_permission!`:

```ruby
  # Standing in the project, without naming a permission. The Workshop subtree
  # needs this; each area below it then asks for the permission it actually
  # uses. Gating the whole subtree on :tasks instead would shut someone who
  # holds only Reporting out of the reports they were deliberately granted.
  def require_project_member!
    return if current_project_access.member?

    deny_access!("You don't have permission to access this page.", product_landing_path)
  end
```

Then:

```ruby
# app/controllers/workshop/base_controller.rb — replace the before_action block

  before_action { require_product!(:workshop) }
  before_action :require_workshop!
  before_action :require_project_member!
  before_action :set_pipeline_badge
```

The ticket surfaces that genuinely need `tasks` — the pipeline, ideas, bugs, design requests, versions, the Jira browser and the process page — each add `before_action { require_permission!(:tasks) }` of their own. Reports and alert rules do not; they ask for `:reporting` and `:automations` in Step 4.

- [ ] **Step 2: Apply the remaining thirteen lines from the table**

Each is a one-line substitution. Example, `app/controllers/brief_commits_controller.rb`:

```ruby
  before_action { require_product!(:workshop) }
  before_action { require_permission!(:configuration) }
```

And `app/controllers/jira_controller.rb`:

```ruby
  before_action -> { require_product!(:workshop) }, except: [ :jira_tasks ]
  before_action -> { require_permission!(:configuration) }, only: [ :projects, :sync ]
  before_action :require_time_hr_or_project_member!, only: [ :jira_tasks ]
```

- [ ] **Step 3: Split the picker's project scope from the Workshop's**

`JiraController#set_project` resolves the project through `visible_jira_projects`
for both its actions. That scope now requires the `tasks` permission, which
would shut the timer bar's picker to an employee who only logs hours. The two
actions want two different questions, so ask them separately:

```ruby
  # app/controllers/jira_controller.rb — replace set_project

  # Two different questions, deliberately kept apart. #jira_tasks is the timer
  # bar's picker: "which projects may this person book time against", which is
  # any project they are on. #sync is Workshop work and wants the Workshop
  # scope, where a membership must actually grant Tasks.
  def set_project
    scope = action_name == "jira_tasks" ? available_projects : visible_jira_projects
    @project = scope.find(params[:id])
  end
```

- [ ] **Step 4: Add the narrower Workshop gates**

```ruby
# app/controllers/workshop/alert_rules_controller.rb — below the existing before_actions
  before_action { require_permission!(:automations) }
```

```ruby
# app/controllers/workshop/reports_controller.rb — below the existing before_actions
  before_action { require_permission!(:reporting) }
```

- [ ] **Step 5: Add the two cases this task makes pass**

Append to `test/controllers/permission_gates_test.rb`:

```ruby
  test "Tasks opens the Jira board and its absence closes it" do
    with_permissions("Project Manager")
    get jira_tasks_path
    assert_response :success

    @membership.update!(tasks: false)
    get jira_tasks_path
    assert_redirected_to root_path
  end

  # The picker is a member route on projects, so its helper takes the project.
  # An employee who logs hours but was never given Workshop work still needs it.
  test "the timer's Jira task picker survives without the Tasks permission" do
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false))

    get jira_tasks_project_path(@project)

    assert_response :success
  end
end
```

Note the closing `end` — append these INSIDE the existing class, before its final `end`.

- [ ] **Step 6: Run the gate test**

Run: `bin/rails test test/controllers/permission_gates_test.rb`
Expected: PASS, every case

- [ ] **Step 7: Verify no controller still calls an old gate**

Run: `grep -rn 'require_workshop_config_access!\|require_workshop_member!\|require_client_or_employee!\|require_workspace_member!' app/controllers`
Expected: no output. The predicates themselves still exist on `User` — Task 9 removes them once the views stop calling them too.

- [ ] **Step 8: Commit**

```bash
git add app/controllers test/controllers/permission_gates_test.rb
git commit -m "feat: every Workshop route is gated on a per-project permission"
```

---

### Task 7: The HR employee directory

**Files:**
- Modify: `app/controllers/workspace_members_controller.rb`, `app/views/workspace_members/new.html.erb`, `app/views/workspace_members/edit.html.erb`, `app/views/workspace_members/index.html.erb`, `app/models/workspace_membership.rb`
- Test: `test/controllers/workspace_members_controller_test.rb` (new)

**Interfaces:**
- Consumes: `workspace_admin` from Task 2, the gates from Task 5.
- Produces: `WorkspaceMembership#last_workspace_admin? -> Boolean`. The directory writes only `time_hr_access` and `workspace_admin`.

**This is the one HR screen that changes,** because it is where the global privilege is granted. The other seventeen HR controllers are untouched. The role select with its four options goes away: a person's Workshop standing is now decided per project, in Configuration › Users, and has no business on this form.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workspace_members_controller_test.rb
require "test_helper"

# The employee directory answers two questions and no longer pretends to
# answer a third. Whether someone is in HR, and whether they run the
# workspace. What they may do inside a project is decided in that project.
class WorkspaceMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin_membership = workspace_memberships(:one_owner)
    @admin_membership.update!(workspace_admin: true)
    sign_in_as(users(:one))
  end

  test "adding a member grants HR access and nothing in any project" do
    assert_difference "User.count", 1 do
      post workspace_members_path, params: {
        name: "New Person", email_address: "new-person@example.com", time_hr_access: "1"
      }
    end

    membership = WorkspaceMembership.joins(:user).find_by(users: { email_address: "new-person@example.com" })
    assert membership.time_hr_access
    assert_not membership.workspace_admin
    assert_equal 0, ProjectMembership.where(user: membership.user).count
  end

  test "an administrator can be promoted and demoted" do
    membership = workspace_memberships(:two_employee)

    patch workspace_member_path(membership), params: { workspace_admin: "1", time_hr_access: "1" }
    assert membership.reload.workspace_admin

    patch workspace_member_path(membership), params: { workspace_admin: "0", time_hr_access: "1" }
    assert_not membership.reload.workspace_admin
  end

  test "the last administrator cannot be demoted" do
    patch workspace_member_path(@admin_membership), params: { workspace_admin: "0", time_hr_access: "1" }

    assert @admin_membership.reload.workspace_admin, "a workspace must keep an administrator"
    assert_equal "A workspace needs at least one administrator.", flash[:alert]
  end

  test "removing an ordinary member works" do
    assert_difference "WorkspaceMembership.count", -1 do
      delete workspace_member_path(workspace_memberships(:two_employee))
    end
  end

  # Deliberately a model assertion, not a request. Through the controller the
  # sole administrator is always the signed-in user, so the "you can't remove
  # yourself" guard fires first and a request test would pass for the wrong
  # reason. The predicate is what the destroy and update guards both consult.
  test "the sole administrator knows it is the last one" do
    assert workspace_memberships(:one_owner).last_workspace_admin?

    workspace_memberships(:two_employee).update!(workspace_admin: true)

    assert_not workspace_memberships(:one_owner).reload.last_workspace_admin?
  end

  test "a membership that is not an admin is never the last one" do
    assert_not workspace_memberships(:two_employee).last_workspace_admin?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/workspace_members_controller_test.rb`
Expected: FAIL — `create` still requires `params[:role]`, and nothing guards the last administrator

- [ ] **Step 3: Add the guard to the model**

```ruby
# app/models/workspace_membership.rb — add below the validations

  # A workspace must keep someone who can run it. Demoting or removing the
  # last administrator is refused rather than silently allowed, because the
  # recovery is a console session.
  def last_workspace_admin?
    return false unless workspace_admin?

    !workspace.workspace_memberships.where(workspace_admin: true).where.not(id: id).exists?
  end
```

- [ ] **Step 4: Rewrite the three controller actions**

```ruby
# app/controllers/workspace_members_controller.rb

  def create
    user = User.find_by(email_address: params[:email_address]&.strip&.downcase)
    new_user = user.nil?

    if new_user
      temp_password = SecureRandom.base58(24)
      user = User.new(name: params[:name], email_address: params[:email_address],
                      password: temp_password, password_confirmation: temp_password)

      unless user.save
        flash.now[:alert] = user.errors.full_messages.to_sentence
        @membership = current_workspace.workspace_memberships.build
        return render :new, status: :unprocessable_entity
      end
    end

    if user.member_of?(current_workspace)
      flash.now[:alert] = "This user is already a member of this workspace."
      @membership = current_workspace.workspace_memberships.build
      return render :new, status: :unprocessable_entity
    end

    # The directory grants HR access and, optionally, the workspace privilege.
    # Nothing here touches any project: Workshop standing is granted per
    # project, in Configuration > Users.
    @membership = current_workspace.workspace_memberships.build(
      user: user,
      time_hr_access: params[:time_hr_access] != "0",
      workspace_admin: params[:workspace_admin] == "1"
    )

    if @membership.save
      mailer = new_user ? :welcome : :added_to_workspace
      InvitationMailer.public_send(mailer, user, current_workspace).deliver_later
      redirect_to workspace_members_path, notice: "#{user.name} added. Invitation email sent."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @membership.last_workspace_admin? && params[:workspace_admin] != "1"
      redirect_to workspace_members_path, alert: "A workspace needs at least one administrator."
      return
    end

    attrs = {
      time_hr_access: params[:time_hr_access] == "1",
      workspace_admin: params[:workspace_admin] == "1"
    }

    if @membership.update(attrs)
      redirect_to workspace_members_path, notice: "Member updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @membership.user == current_user
      redirect_to workspace_members_path, alert: "You can't remove yourself."
      return
    end

    if @membership.last_workspace_admin?
      redirect_to workspace_members_path, alert: "A workspace needs at least one administrator."
      return
    end

    name = @membership.user.name
    @membership.destroy
    redirect_to workspace_members_path, notice: "#{name} removed.", status: :see_other
  end
```

- [ ] **Step 5: Replace the role select in both forms**

In `app/views/workspace_members/new.html.erb` and `edit.html.erb`, delete the Role select and its four-paragraph explanation, and the Workshop checkbox from the edit form. Put this in their place:

```erb
      <div class="space-y-2 pt-4" style="border-top: 1px solid var(--color-outline-variant)">
        <label class="text-sm font-medium" style="color: var(--color-on-surface-variant)">Access</label>
        <p class="text-xs" style="color: var(--color-outline)">
          What this person may do inside a project is set in that project, under Configuration &rsaquo; Users.
        </p>

        <input type="hidden" name="time_hr_access" value="0">
        <label class="flex items-center justify-between gap-4 cursor-pointer">
          <span class="text-sm" style="color: var(--color-on-surface)">Time &amp; HR</span>
          <input type="checkbox" name="time_hr_access" value="1" class="m3-checkbox"
                 <%= "checked" if @membership.time_hr_access %>>
        </label>

        <input type="hidden" name="workspace_admin" value="0">
        <label class="flex items-center justify-between gap-4 cursor-pointer">
          <span class="text-sm" style="color: var(--color-on-surface)">Workspace administrator</span>
          <input type="checkbox" name="workspace_admin" value="1" class="m3-checkbox"
                 <%= "checked" if @membership.workspace_admin %>>
        </label>
        <p class="text-xs" style="color: var(--color-outline)">
          An administrator creates projects, runs Time &amp; HR, and holds every permission in every project.
        </p>
      </div>
```

For `new.html.erb` the membership is unsaved, so replace `@membership.time_hr_access` with `true` and `@membership.workspace_admin` with `false` in the two `checked` expressions.

- [ ] **Step 6: Close the seam this screen opens**

Promoting someone here is the first time a workspace admin can exist whose old
`role` is still `employee`. `available_projects` in
`app/controllers/concerns/workspace_scoped.rb` still asks the OLD role
predicate, so that person would see no projects at all — no projects to book
time against, and a refused Jira task picker, because
`require_time_hr_or_project_member!` falls back to this method. Point it at the
flag:

```ruby
  # Projects this person may book time against. A workspace admin sees every
  # one; everyone else sees the projects they are on. Deliberately NOT
  # visible_jira_projects, which additionally requires the Tasks permission —
  # booking hours is an HR action and must not need Workshop standing.
  def available_projects
    return current_workspace.projects.active.order(:name) if workspace_admin?

    current_workspace.projects.active
      .joins(:project_memberships)
      .where(project_memberships: { user_id: current_user.id })
      .order(:name)
  end
```

- [ ] **Step 7: Fix the index view**

In `app/views/workspace_members/index.html.erb`, replace any `membership.role` display with:

```erb
<%= membership.workspace_admin? ? "Administrator" : "Member" %>
<%= " · Time & HR" if membership.time_hr_access %>
```

- [ ] **Step 8: Run the tests**

Run: `bin/rails test test/controllers/workspace_members_controller_test.rb test/controllers/permission_gates_test.rb`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add app/controllers/workspace_members_controller.rb app/controllers/concerns/workspace_scoped.rb app/views/workspace_members \
  app/models/workspace_membership.rb test/controllers/workspace_members_controller_test.rb
git commit -m "feat: the employee directory grants HR access and the workspace privilege, nothing more"
```

---

### Task 8: Views, and the locked Configuration tabs

**Files:**
- Modify: `app/controllers/workshop/configuration_controller.rb`, `app/views/workshop/configuration/show.html.erb`, `app/helpers/clar_helper.rb`, `app/views/layouts/_clar_sidebar.html.erb`, `app/views/layouts/_clar_topbar.html.erb`, `app/views/workshop/reports/_metrics.html.erb`, `app/views/workshop/reports/_dev_table.html.erb`, `app/views/reports/detaileds/show.html.erb`, `app/views/dashboard/show.html.erb`, `app/views/jira_tasks/index.html.erb`, `app/views/task_breakdowns/show.html.erb`, `app/views/workshop/pipeline/index.html.erb`, `app/views/workshop/pipeline/no_project.html.erb`, `app/views/application.html.erb`
- Test: `test/controllers/permission_gates_test.rb`, `test/helpers/clar_helper_role_badge_test.rb` (new)

**Interfaces:**
- Consumes: `can?`, `workspace_admin?` from Task 5, `ProjectAccess#role_label` from Task 3.
- Produces: `ClarHelper#permission_role_badge(access_or_membership) -> [String, String]` replacing `workshop_role_badge`.

**Tab permissions.** `integrations`, `ai` and `users` need `configuration`. `briefing` needs `briefing_config`. The page opens for anyone holding either; with neither it is refused. A tab you lack renders with a padlock and an explanation, and is refused server-side as well.

- [ ] **Step 1: Write the failing test**

```ruby
# test/helpers/clar_helper_role_badge_test.rb
require "test_helper"

# The badge names what the switches add up to. It must not invent a role that
# the switches do not describe — "Custom" is the honest answer when someone has
# tuned their own combination.
class ClarHelperRoleBadgeTest < ActionView::TestCase
  include ClarHelper

  test "a preset gets its name and a custom set says so" do
    membership = project_memberships(:two_elvium)

    membership.update!(PermissionPreset.attributes_for("Product Owner"))
    assert_equal "Product Owner", permission_role_badge(membership).last

    membership.update!(pricing: true)
    assert_equal "Custom", permission_role_badge(membership).last
  end

  test "an administrator badge is the warning colour" do
    membership = project_memberships(:two_elvium)
    membership.update!(PermissionPreset.attributes_for("Administrator"))

    assert_equal "clar-badge-warn", permission_role_badge(membership).first
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/helpers/clar_helper_role_badge_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'permission_role_badge'`

- [ ] **Step 3: Replace the badge helper**

In `app/helpers/clar_helper.rb`, delete `workshop_role_badge` and add:

```ruby
  # Configuration > Users: [badge_class, label] for a project membership or a
  # ProjectAccess. The label is derived from the switches, so a set matching no
  # preset reads "Custom" rather than being rounded to the nearest role.
  def permission_role_badge(holder)
    label = holder.role_label
    klass = case label
            when "Administrator" then "clar-badge-warn"
            when "Custom" then "clar-badge-muted"
            else "clar-badge-primary"
            end
    [ klass, label ]
  end
```

- [ ] **Step 4: Gate the Configuration tabs**

Replace the gating block of `app/controllers/workshop/configuration_controller.rb`:

```ruby
  TABS = %w[integrations ai briefing users].freeze

  # What each tab costs. Briefing is the one a Product Owner holds, which is
  # why this is a per-tab map and not a single gate on the page.
  TAB_PERMISSIONS = {
    "integrations" => :configuration,
    "ai" => :configuration,
    "briefing" => :briefing_config,
    "users" => :configuration
  }.freeze

  before_action :require_configuration_access!
  before_action :redirect_to_a_tab_they_hold, only: :show

  def show
    @tab = requested_tab
    load_ai_tab if @tab == "ai"
    load_briefing_tab if @tab == "briefing"
    load_integrations_tab if @tab == "integrations"
    load_users_tab if @tab == "users"
  end

  private

  # The page opens for either permission; with neither there is nothing on it.
  def require_configuration_access!
    return if can?(:configuration) || can?(:briefing_config)

    deny_access!("You don't have permission to access this page.", product_landing_path)
  end

  def requested_tab
    TABS.include?(params[:tab]) ? params[:tab] : default_tab
  end

  # The first tab this person actually holds, so the bare URL never lands on a
  # padlock.
  def default_tab
    can?(:configuration) ? "ai" : "briefing"
  end

  def tab_permitted?(tab)
    can?(TAB_PERMISSIONS.fetch(tab, :configuration))
  end
  helper_method :tab_permitted?

  def redirect_to_a_tab_they_hold
    return if tab_permitted?(requested_tab)

    redirect_to workshop_configuration_path(tab: default_tab),
                alert: "You don't have permission to open that tab."
  end
```

Delete `ADMIN_ONLY_TABS`, `block_admin_only_tabs` and the old `before_action :require_workshop_config_access!`. In `update`, add `return head :forbidden unless tab_permitted?(tab)` after the tab is resolved.

- [ ] **Step 5: Render locked tabs**

Replace the tab strip in `app/views/workshop/configuration/show.html.erb`:

```erb
<div class="clar-tabs mb-6">
  <% { "integrations" => "Integrations", "ai" => "AI",
       "briefing" => "Briefing", "users" => "Users" }.each do |tab, label| %>
    <% if tab_permitted?(tab) %>
      <%= link_to label, workshop_configuration_path(tab: tab),
            class: "clar-tab #{'clar-tab-active' if @tab == tab}" %>
    <% else %>
      <%# Shown but locked. That it exists, and why it is shut, is more use
          than a tab that silently is not there. The controller refuses it
          server-side too, so this is presentation and not the gate. %>
      <span class="clar-tab clar-tip inline-flex items-center gap-1.5 cursor-not-allowed opacity-60"
            data-tip="Missing permission &mdash; ask an administrator"
            aria-label="Missing permission" tabindex="0" aria-disabled="true">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>
        <%= label %>
      </span>
    <% end %>
  <% end %>
</div>
```

Replace the `is_admin` header line with `<% is_admin = can?(:configuration) %>`, and the body dispatch with `<%= render "#{@tab}_tab" %>`.

- [ ] **Step 6: Replace the remaining view predicates**

Apply these substitutions across the view files listed at the top of this task:

| In a view, replace | With |
| --- | --- |
| `can_see_money?` in `workshop/reports/_metrics.html.erb` and `_dev_table.html.erb` | `can?(:pricing)` |
| `can_see_money?` in `reports/detaileds/show.html.erb` | `workspace_admin?` |
| `current_user.admin_or_owner?(current_workspace)` in Workshop views | `can?(:configuration)` |
| `current_user.admin_or_owner?(current_workspace)` in HR views (`dashboard/show`, `reports/*`) | `workspace_admin?` |
| `current_user.client_role?(current_workspace)` | `!can?(:configuration)` |
| `membership.workshop_access?` in `_clar_sidebar.html.erb` | `can?(:tasks)` |
| `workshop_role_badge(...)` | `permission_role_badge(...)` |

- [ ] **Step 7: Verify no view still calls an old predicate**

Run: `grep -rn 'admin_or_owner?\|can_see_money?\|workshop_role_badge\|workshop_access?' app/views app/helpers`
Expected: no output. `client_role?` survives in `workspace_scoped.rb` until Task 9.

- [ ] **Step 8: Add the tab cases this task makes pass**

Append to `test/controllers/permission_gates_test.rb`:

```ruby
  test "Configuration opens for an Administrator" do
    with_permissions("Administrator")

    get workshop_configuration_path(tab: "integrations")

    assert_response :success
  end

  test "a Product Owner reaches Briefing but not Integrations" do
    with_permissions("Product Owner")

    get workshop_configuration_path(tab: "briefing")
    assert_response :success

    get workshop_configuration_path(tab: "integrations")
    assert_redirected_to workshop_configuration_path(tab: "briefing")
  end

  test "a Project Manager cannot open the configuration page at all" do
    with_permissions("Project Manager")

    get workshop_configuration_path(tab: "briefing")

    assert_response :redirect
  end

  # Until this task, the Configuration controller gated on the retired role
  # predicate while workshop_landing_path already sent Configuration-only
  # people here — so this leg of the landing chain bounced. It is the last
  # unproven branch of the redirect-loop fix.
  test "the landing chain's Configuration leg actually lands" do
    @membership.update!(PermissionPreset::PERMISSIONS.index_with(false).merge(configuration: true))

    get workshop_pipeline_path
    follow_redirect!

    assert_response :success
  end
```

- [ ] **Step 9: Run the affected tests**

Run: `bin/rails test test/helpers/clar_helper_role_badge_test.rb test/controllers/permission_gates_test.rb test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add app/controllers/workshop/configuration_controller.rb app/views app/helpers/clar_helper.rb \
  test/controllers/permission_gates_test.rb test/helpers/clar_helper_role_badge_test.rb
git commit -m "feat: Configuration locks the tabs you lack, and views ask the new permissions"
```

---

### Task 9: Retire the legacy role tests

**Files:**
- Delete: `test/models/client_role_test.rb`, `test/controllers/client_access_test.rb` (`test/controllers/workspace_client_time_hr_test.rb` was already deleted in Task 7, which is what broke it)
- Modify: `test/models/user_test.rb`, `test/fixtures/workspace_memberships.yml`, `test/fixtures/project_memberships.yml`, and the role-dependent setups in `test/controllers/brief_chat_sessions_controller_test.rb`, `test/controllers/chat_sessions_controller_test.rb`, `test/controllers/jira_controller_test.rb`, `test/controllers/jira_tasks_controller_test.rb`, `test/controllers/workshop_controller_test.rb`, `test/controllers/workshop/configuration_controller_test.rb`, `test/controllers/workshop/discord_webhooks_controller_test.rb`, `test/controllers/workshop/reports_controller_test.rb`

**Interfaces:**
- Consumes: everything from Tasks 1 through 8.
- Produces: fixtures expressing the new model, which every later task's tests rely on.

The three deleted files test a role that no longer exists. Their intent — that a restricted person cannot reach another project's data — is already covered by `permission_gates_test.rb` and the scoping test added below.

- [ ] **Step 1: Update the fixtures**

```yaml
# test/fixtures/workspace_memberships.yml
one_owner:
  user: one
  workspace: one
  role: 2
  workspace_admin: true
  time_hr_access: true
  workshop_access: true

two_employee:
  user: two
  workspace: one
  role: 0
  workspace_admin: false
  time_hr_access: true
  workshop_access: false

# Was the Jira-only `client` role: now simply a person holding Tasks and
# nothing else, with no HR account.
client_membership:
  user: client_user
  workspace: one
  role: 3
  workspace_admin: false
  time_hr_access: false
  workshop_access: false

# Was `workspace_client`: a Product Owner who also logs their own hours.
workspace_client_membership:
  user: workspace_client_user
  workspace: one
  role: 4
  workspace_admin: false
  time_hr_access: true
  workshop_access: true
```

`role` and `workshop_access` stay until Task 18 removes the columns; the backfill test in Task 4 reads them.

```yaml
# test/fixtures/project_memberships.yml — add the switches to each existing entry
one_elvium:
  project: jira_project
  user: one
  hourly_rate_cents: 15000
  automations: true
  tasks: true
  reporting: true
  pricing: true
  briefing_config: true
  configuration: true

two_elvium:
  project: jira_project
  user: two
  hourly_rate_cents: 10000
  automations: true
  tasks: true
  reporting: true
  pricing: false
  briefing_config: false
  configuration: false

one_internal:
  project: plain_project
  user: one
  hourly_rate_cents: 12000
  automations: true
  tasks: true
  reporting: true
  pricing: true
  briefing_config: true
  configuration: true

# Tasks only, and on jira_project alone, so scoping tests can assert they
# cannot reach SecretProject.
client_elvium:
  project: jira_project
  user: client_user
  hourly_rate_cents: 0
  automations: false
  tasks: true
  reporting: false
  pricing: false
  briefing_config: false
  configuration: false

workspace_client_elvium:
  project: jira_project
  user: workspace_client_user
  hourly_rate_cents: 0
  automations: true
  tasks: true
  reporting: true
  pricing: false
  briefing_config: true
  configuration: false
```

- [ ] **Step 2: Delete the three obsolete files**

```bash
git rm test/models/client_role_test.rb test/controllers/client_access_test.rb
```

- [ ] **Step 3: Cover the flag-only administrator**

After Task 7, promoting someone makes a workspace admin whose old `role`
column still reads `employee`. That combination is now the ordinary case for
anyone promoted through the interface, and nothing isolates it end to end. Add
to `test/controllers/permission_gates_test.rb`:

```ruby
  # A person promoted through the HR directory carries workspace_admin without
  # ever having had an admin ROLE. Everything that used to ask the role has to
  # answer for them too — available_projects is the one that bit us.
  test "an administrator by flag alone sees every project" do
    workspace_memberships(:two_employee).update!(workspace_admin: true)
    ProjectMembership.where(user: @user).destroy_all

    get new_time_entry_path

    assert_response :success
    assert_select "select#time_entry_project_id option", minimum: 2
  end
```

Confirm the select's id against the markup before relying on it; Task 7's
`time_hr_access_test.rb` uses the same selector and is a good reference.

- [ ] **Step 4: Add the scoping test that replaces them**

```ruby
# test/controllers/project_scoping_test.rb
require "test_helper"

# What the deleted client-role tests were really protecting: a restricted
# person must not reach a project they were never added to. The rule now comes
# from the membership rather than from a hard-coded redirect, so it is worth
# asserting directly.
class ProjectScopingTest < ActionDispatch::IntegrationTest
  test "a member sees only the projects they are on" do
    sign_in_as(users(:client_user))
    get jira_tasks_path

    assert_response :success
    assert_match projects(:jira_project).name, response.body
    assert_no_match projects(:other_jira_project).name, response.body
  end

  test "a workspace admin sees every project" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))
    get jira_tasks_path

    assert_response :success
    assert_match projects(:other_jira_project).name, response.body
  end
end
```

- [ ] **Step 5: Fix the setups in the eight remaining test files**

Each sets a role to arrange a case. Translate as follows, leaving the assertions alone:

**Three carried-over fixes to the Task 4 backfill test**, which the Task 4 review
raised and which are cheapest to make here, while you are already in the
fixtures:

- Its "a client keeps Tasks only and loses HR" case asserts `time_hr_access` is
  false, but the `client_membership` fixture already ships it false, so that
  half of the test would pass even with the revocation deleted. Set
  `time_hr_access: true` on that membership inside the test before running the
  backfill, so the assertion proves something.
- No fixture carries `role: 1` (plain `admin`); only `role: 2` is exercised,
  though both share a branch. Add a case that sets a membership's role to 1 and
  asserts it too becomes a workspace admin.
- Its idempotency case diffs only the six permission columns. Widen the pluck to
  include `workspace_admin` on `WorkspaceMembership` as well.

One file outside that list also breaks the moment the enum declaration goes:
`test/jobs/holiday_yearly_grant_job_test.rb:22` passes `role: :client` when
building a membership. Drop that argument — the job has nothing to do with
roles, and the membership it builds only needs `time_hr_access`.

| Old setup | New setup |
| --- | --- |
| `membership.update!(role: :admin)` | `membership.update!(workspace_admin: true)` |
| `membership.update!(role: :employee, workshop_access: true)` | `project_membership.update!(PermissionPreset.attributes_for("Project Manager"))` |
| `membership.update!(role: :client)` | `project_membership.update!(PermissionPreset.attributes_for("Project Manager").merge(automations: false, reporting: false))` |
| `membership.update!(role: :workspace_client)` | `project_membership.update!(PermissionPreset.attributes_for("Product Owner"))` |

- [ ] **Step 6: Run every test touched so far**

Run each file separately — the local `pg` gem segfaults on the full suite:

```bash
for f in test/models/permission_preset_test.rb test/models/project_membership_permissions_test.rb \
         test/services/project_access_test.rb test/models/product_access_test.rb \
         test/controllers/permission_gates_test.rb test/controllers/project_scoping_test.rb \
         test/controllers/workspace_members_controller_test.rb \
         test/controllers/workshop/configuration_controller_test.rb; do
  bin/rails test "$f" || echo "FAILED: $f"
done
```

Expected: no `FAILED:` lines

- [ ] **Step 7: Delete the old model, now that nothing calls it**

Every caller is gone as of Task 8, so remove the predicates in one sweep.

From `app/models/user.rb`: `role_in`, `admin_or_owner?`, `at_least_employee?`, `client_role?`, `workspace_client_role?`, `client_or_employee?`, `can_see_money?`, `time_hr_member?`.

From `app/controllers/concerns/authorization.rb`: `require_workshop_config_access!`, `require_client_or_employee!`, `require_workshop_member!`, `require_workspace_member!`, `workshop_config_manager?`, `can_see_money?`, `current_role` (verified to have no callers at all), and their entries in the `helper_method` list.

From `app/models/workspace_membership.rb`: the `enum :role, ...` declaration and the comment block above it. Leave the column — Task 18 drops it.

From `app/controllers/concerns/workspace_scoped.rb`: `redirect_clients_to_jira`, its `before_action`, the `CLIENT_ALLOWED_PREFIXES` and `CLIENT_ALLOWED_EXACT_PATHS` constants, and the `client_role?` branch of `product_landing_path`, which becomes:

```ruby
  # Landing path for a product. For the Workshop that is whichever page this
  # person can actually open — see workshop_landing_path, added in Task 6 to
  # fix an infinite redirect. Returning the pipeline unconditionally would send
  # someone who lacks Tasks to a page that immediately refuses them.
  def product_landing_path(product = current_product)
    return time_entries_path unless product&.to_sym == :workshop

    workshop_landing_path
  end
```

**Do not replace the whole method from memory.** Remove only the `client_role?` line; `workshop_landing_path` must stay as the return.

Then confirm nothing survives:

```bash
grep -rn 'admin_or_owner?\|client_role?\|workspace_client\|at_least_employee?\|can_see_money?\|client_or_employee?\|time_hr_member?\|workshop_config_manager?\|require_workshop_config_access!\|require_workshop_member!\|require_client_or_employee!\|require_workspace_member!\|redirect_clients_to_jira' app lib
```

Expected: no output.

- [ ] **Step 8: Re-run every test touched so far**

Repeat the loop from Step 5. Expected: no `FAILED:` lines.

- [ ] **Step 8: Commit**

```bash
git add -A app test
git commit -m "test: express the suite in per-project permissions instead of workspace roles"
```

---

## Phase C — configuration moves into the project

### Task 10: The configuration columns

**Files:**
- Create: `db/migrate/20260912122000_move_configuration_to_projects.rb`, `db/migrate/20260912123000_backfill_project_configuration.rb`
- Modify: `app/models/project.rb`
- Test: `test/migrations/backfill_project_configuration_test.rb`

**Interfaces:**
- Consumes: nothing from earlier phases.
- Produces: on `projects` — `team`, `figma_token`, `figma_read_enabled`, `anthropic_api_key`, `pr_review_enabled`, `pr_review_prompt`, `pr_poll_minutes`, `pr_polled_at`, `estimation_trigger`, `estimation_status_trigger`, `estimation_field_names`, `jira_ai_actions_field_id`, `jira_ai_estimation_field_id`, `jira_story_points_field_id`, and `jira_`/`github_`/`figma_` status triples.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260912122000_move_configuration_to_projects.rb

# A project is the unit of work, so its keys and its AI settings belong to it.
# There was exactly one GitHub token on the workspace, which is one fewer than
# the number of clients.
#
# Guarded per column: MySQL commits DDL outside the migration transaction, so a
# failure part-way must leave a re-runnable state.
class MoveConfigurationToProjects < ActiveRecord::Migration[8.1]
  COLUMNS = [
    [ :team, :string, {} ],
    [ :figma_token, :text, {} ],
    [ :figma_read_enabled, :boolean, { default: false, null: false } ],
    [ :anthropic_api_key, :text, {} ],
    [ :pr_review_enabled, :boolean, { default: false, null: false } ],
    [ :pr_review_prompt, :text, {} ],
    [ :pr_poll_minutes, :integer, { default: 7, null: false } ],
    [ :pr_polled_at, :datetime, {} ],
    [ :estimation_trigger, :string, { default: "manual", null: false } ],
    [ :estimation_status_trigger, :string, { default: "Ready for dev" } ],
    [ :estimation_field_names, :json, {} ],
    [ :jira_ai_actions_field_id, :string, {} ],
    [ :jira_ai_estimation_field_id, :string, {} ],
    [ :jira_story_points_field_id, :string, {} ],
    [ :jira_status_ok, :boolean, {} ],
    [ :jira_status_error, :string, {} ],
    [ :jira_status_checked_at, :datetime, {} ],
    [ :github_status_ok, :boolean, {} ],
    [ :github_status_error, :string, {} ],
    [ :github_status_checked_at, :datetime, {} ],
    [ :figma_status_ok, :boolean, {} ],
    [ :figma_status_error, :string, {} ],
    [ :figma_status_checked_at, :datetime, {} ]
  ].freeze

  def up
    COLUMNS.each do |name, type, options|
      next if column_exists?(:projects, name)
      add_column :projects, name, type, **options
    end
  end

  def down
    COLUMNS.each { |name, _, _| remove_column :projects, name if column_exists?(:projects, name) }
  end
end
```

- [ ] **Step 2: Write the backfill**

```ruby
# db/migrate/20260912123000_backfill_project_configuration.rb

# Copies the workspace's single set of settings down to every project, so no
# project starts blank on the day the workspace columns stop being read.
class BackfillProjectConfiguration < ActiveRecord::Migration[8.1]
  COPIED = %i[
    figma_read_enabled pr_review_enabled pr_review_prompt pr_poll_minutes
    estimation_trigger estimation_status_trigger estimation_field_names
    jira_ai_actions_field_id jira_ai_estimation_field_id jira_story_points_field_id
  ].freeze

  def up
    Project.reset_column_information
    Workspace.reset_column_information

    say_with_time "copying workspace configuration down to projects" do
      Workspace.find_each do |workspace|
        attrs = COPIED.index_with { |column| workspace.read_attribute(column) }.compact
        # github_repo/github_token are already per-project columns; only fill
        # the ones a project has not set for itself.
        workspace.projects.find_each do |project|
          fill = attrs.reject { |column, _| project.read_attribute(column).present? }
          fill[:github_repo] ||= workspace.github_repo if project.github_repo.blank?
          fill[:github_token] ||= workspace.github_token if project.github_token.blank?
          project.update_columns(fill) if fill.any?
        end
      end
    end
  end

  def down; end
end
```

- [ ] **Step 3: Declare the new secrets as encrypted**

```ruby
# app/models/project.rb — extend the existing encrypts block
  encrypts :github_token
  encrypts :jira_api_token
  encrypts :figma_token
  encrypts :anthropic_api_key
```

- [ ] **Step 4: Write the backfill test**

```ruby
# test/migrations/backfill_project_configuration_test.rb
require "test_helper"
require Rails.root.join("db/migrate/20260912123000_backfill_project_configuration")

class BackfillProjectConfigurationTest < ActiveSupport::TestCase
  test "every project inherits the workspace settings it has not set itself" do
    workspaces(:one).update!(pr_review_enabled: true, pr_poll_minutes: 11,
                             github_repo: "acme/widgets", github_token: "wt")
    projects(:jira_project).update!(github_repo: "acme/own")

    BackfillProjectConfiguration.new.up

    inherited = projects(:plain_project).reload
    assert inherited.pr_review_enabled
    assert_equal 11, inherited.pr_poll_minutes
    assert_equal "acme/widgets", inherited.github_repo

    assert_equal "acme/own", projects(:jira_project).reload.github_repo,
                 "a project that set its own repo keeps it"
  end
end
```

- [ ] **Step 5: Run and verify**

Run: `bin/rails db:migrate && bin/rails test test/migrations/backfill_project_configuration_test.rb`
Expected: PASS, 1 run

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260912122000_move_configuration_to_projects.rb \
  db/migrate/20260912123000_backfill_project_configuration.rb db/schema.rb \
  app/models/project.rb test/migrations/backfill_project_configuration_test.rb
git commit -m "feat: projects carry their own integration keys and AI settings"
```

---

### Task 11: Read the configuration from the project

**Files:**
- Modify: `app/services/project_credentials.rb`, `app/services/project_mcp_config.rb`, `app/services/figma_client.rb`, `app/jobs/integration_health_job.rb`, `app/jobs/pr_review_job.rb`, `app/jobs/pr_review_check_job.rb`
- Test: `test/services/project_credentials_test.rb`, `test/jobs/integration_health_job_test.rb` (rewritten)

**Interfaces:**
- Consumes: the columns from Task 10.
- Produces: `ProjectCredentials#figma_token`, `#anthropic_api_key`, `#figma_configured?`; `FigmaClient.for_project(project) -> FigmaClient`; `IntegrationHealthJob` writing status onto the project.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/project_credentials_test.rb
require "test_helper"

# One place answers "what credentials does this project use". The workspace
# fallback is gone: a second client's keys have nowhere to fall back TO, and a
# silent fallback to the first client's token is worse than a blank field.
class ProjectCredentialsTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "reads the project's own keys" do
    @project.update!(github_repo: "acme/own", github_token: "pt", figma_token: "ft")
    credentials = ProjectCredentials.new(@project)

    assert_equal "acme/own", credentials.github_repo
    assert_equal "pt", credentials.github_token
    assert_equal "ft", credentials.figma_token
    assert credentials.figma_configured?
  end

  test "does not borrow the workspace's key" do
    @project.update!(github_token: nil)
    @project.workspace.update!(github_token: "workspace-token")

    assert_nil ProjectCredentials.new(@project).github_token
  end

  test "the AI key falls back to the environment, which is how the CLI already runs" do
    @project.update!(anthropic_api_key: nil)

    ENV.stub(:[], ->(k) { k == "ANTHROPIC_API_KEY" ? "env-key" : nil }) do
      assert_equal "env-key", ProjectCredentials.new(@project).anthropic_api_key
    end
  end
end
```

`ENV.stub` needs `require "minitest/mock"`; if the stub proves awkward, set and restore `ENV["ANTHROPIC_API_KEY"]` around the assertion in an `ensure` block instead.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/project_credentials_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'figma_token'`

- [ ] **Step 3: Extend ProjectCredentials and drop the workspace fallback**

```ruby
# app/services/project_credentials.rb

# Single source of truth for "what credentials does this project use".
#
# Resolution is the project column, then ENV for the two things that are
# genuinely machine-wide (Jira's domain and the AI key). The old fallback to
# the workspace column is gone: with more than one client, falling back means
# quietly using the wrong client's token.
class ProjectCredentials
  def initialize(project)
    @project = project
  end

  def github_repo = @project.github_repo.presence
  def github_token = @project.github_token.presence
  def jira_site = @project.jira_site.presence || ENV["JIRA_DOMAIN"].presence
  def jira_email = @project.jira_email.presence || ENV["JIRA_EMAIL"].presence
  def jira_api_token = @project.jira_api_token.presence || ENV["JIRA_API_TOKEN"].presence
  def jira_key = @project.external_reference.presence
  def figma_token = @project.figma_token.presence
  def anthropic_api_key = @project.anthropic_api_key.presence || ENV["ANTHROPIC_API_KEY"].presence

  def github_configured? = github_repo.present? && github_token.present?
  def jira_configured? = jira_site.present? && jira_email.present? && jira_api_token.present?
  def figma_configured? = @project.figma_read_enabled? && figma_token.present?
end
```

- [ ] **Step 4: Point FigmaClient at the project**

```ruby
# app/services/figma_client.rb — replace self.for_cli

  # The token the AI would actually use for THIS project. Reading anything else
  # would prove only that some other token works.
  def self.for_project(project)
    new(token: ProjectCredentials.new(project).figma_token || cli_token)
  end
```

Keep `cli_token` and `CONFIG_PATH`: they remain the fallback for a project that has not set its own token, which is every project on the day this ships.

- [ ] **Step 5: Check health per project**

```ruby
# app/jobs/integration_health_job.rb — replace perform and the three checks

  def perform
    Project.active.find_each do |project|
      check_jira(project)
      check_github(project)
      check_figma(project)
    rescue StandardError => e
      # One broken project must not stop the rest from being checked.
      Rails.logger.error("[IntegrationHealthJob] project #{project.id} failed: #{e.message}")
    end
  end

  private

  def check_jira(project)
    credentials = ProjectCredentials.new(project)
    return unless credentials.jira_configured?

    store(project, :jira, JiraClient.new(domain: credentials.jira_site,
                                         email: credentials.jira_email,
                                         api_token: credentials.jira_api_token).health_check)
  end

  def check_github(project)
    client = GithubClient.for_project(project)
    return unless client.configured?

    store(project, :github, client.health_check)
  end

  def check_figma(project)
    return unless project.figma_read_enabled?

    store(project, :figma, FigmaClient.for_project(project).health_check)
  end

  def store(project, integration, result)
    project.update_columns(
      "#{integration}_status_ok" => result[:ok],
      "#{integration}_status_error" => result[:error],
      "#{integration}_status_checked_at" => Time.current
    )
  end
```

- [ ] **Step 6: Give the MCP config the project's Figma and AI keys**

`ProjectMcpConfig` already builds each project's `.mcp.json` from
`ProjectCredentials`. Add a `figma` server entry, gated on
`ProjectCredentials#figma_configured?` rather than on an environment variable,
so a project without its own token simply gets no Figma server instead of one
that fails on first use:

```ruby
  # app/services/project_mcp_config.rb — alongside the existing servers
  def figma_server
    return nil unless credentials.figma_configured?

    { "command" => "npx",
      "args" => [ "-y", "figma-developer-mcp", "--stdio" ],
      "env" => { "FIGMA_API_KEY" => credentials.figma_token } }
  end
```

Register it in the servers hash the same way the existing entries are, skipping
`nil`. Remember Zeitwerk: anything added under `lib/mcp` stays ignored by
`config.autoload_lib`.

- [ ] **Step 7: Point the PR review jobs at the project**

In `app/jobs/pr_review_check_job.rb` and `app/jobs/pr_review_job.rb`, replace every `workspace.github_*`, `workspace.pr_review_enabled`, `workspace.pr_poll_minutes`, `workspace.pr_polled_at` and `workspace.pr_review_prompt` read with the project equivalent, and iterate `Project.active.where(pr_review_enabled: true)` instead of the workspaces. `GithubClient.for(workspace)` becomes `GithubClient.for_project(project)`.

- [ ] **Step 8: Rewrite the health job test**

Change `test/jobs/integration_health_job_test.rb` to set up a project rather than a workspace, and assert the status lands on `projects(:jira_project)`. Keep all four cases, including "a project that raises does not stop the others" — swap the workspace id for a project id in the exploding stub, and remember that inside `define_singleton_method` `self` is the class, so capture the id in a local first.

- [ ] **Step 9: Run the tests**

Run: `bin/rails test test/services/project_credentials_test.rb test/jobs/integration_health_job_test.rb`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add app/services app/jobs test/services/project_credentials_test.rb test/jobs/integration_health_job_test.rb
git commit -m "feat: credentials, health checks and PR review resolve per project"
```

---

### Task 11b: Stop the backfill fanning one repo out to every project

Task 10's backfill copies the workspace's single configuration down to **every** project.
On the real production database that means one GitHub repo (`elviumcom/elvium`) and
`pr_review_enabled: true` land on all 13 projects, 12 of which have no Jira key and no
repo of their own. After Task 11 points `PrReviewCheckJob` at
`Project.active.where(pr_review_enabled: true)`, that is 13 pollers against one repository
every 7 minutes, and up to 13 AI reviews queued for the same pull request — the exact
token burn that was fixed by hand a fortnight ago, reintroduced by a migration. The same
fan-out turns one Figma health check into 13.

Verified against a copy of the production database, not inferred: workspace 1 holds
`github_repo = elviumcom/elvium`, `pr_review_enabled = 1`, `figma_read_enabled = 1`; all 13
of its projects hold `github_repo = NULL`; and exactly one project (Elvium, id 1) has
`external_type = "jira"`.

Fix it with a new corrective migration rather than by editing Task 10's, which has already
run on every developer database: a forward-only correction is honest about the history and
is safe to run on a database that never saw the mistake.

**Files:**
- Create: `db/migrate/20260912123500_narrow_project_configuration_fanout.rb`
- Test: `test/migrations/narrow_project_configuration_fanout_test.rb`

**Interfaces:**
- Consumes: the columns and the backfill from Task 10.
- Produces: nothing new. It only removes values that should not have been copied.

- [ ] **Step 1: Write the failing test**

```ruby
# test/migrations/narrow_project_configuration_fanout_test.rb
require "test_helper"
require Rails.root.join("db/migrate/20260912123500_narrow_project_configuration_fanout.rb")

# The settings that cost money or make outbound calls belong to the one project
# the integration was really about. Everything else keeps what it inherited.
class NarrowProjectConfigurationFanoutTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_repo: "acme/app", pr_review_enabled: true, figma_read_enabled: true)
    # jira_project is the workspace's only external_type: "jira" project.
    @primary = projects(:jira_project)
    @other = projects(:plain_project)

    [ @primary, @other ].each do |project|
      project.update_columns(github_repo: "acme/app", pr_review_enabled: true, figma_read_enabled: true)
    end
  end

  test "the Jira project keeps the repo and the polling" do
    NarrowProjectConfigurationFanout.new.up

    @primary.reload
    assert_equal "acme/app", @primary.github_repo
    assert @primary.pr_review_enabled
    assert @primary.figma_read_enabled
  end

  test "every other project loses the copied repo and stops polling" do
    NarrowProjectConfigurationFanout.new.up

    @other.reload
    assert_nil @other.github_repo
    assert_not @other.pr_review_enabled
    assert_not @other.figma_read_enabled
  end

  test "a value the project set for itself is left alone" do
    @other.update_columns(github_repo: "acme/its-own")

    NarrowProjectConfigurationFanout.new.up

    assert_equal "acme/its-own", @other.reload.github_repo
  end

  test "with no single Jira project nothing is designated and nothing is cleared" do
    @primary.update_columns(external_type: nil)

    NarrowProjectConfigurationFanout.new.up

    assert_equal "acme/app", @other.reload.github_repo
    assert_equal "acme/app", @primary.reload.github_repo
  end
end
```

The last case is the conservative half of the rule and matters more than the others: where
the migration cannot tell which project owns the integration, it must change nothing and
leave the decision to a person. Check whether `projects(:other_jira_project)` also carries
`external_type: "jira"` in the same workspace — if it does, the first two cases have no
single primary either, and you must set its `external_type` to nil in `setup` and say so in
your report.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/migrations/narrow_project_configuration_fanout_test.rb`
Expected: FAIL — `LoadError`, the migration file does not exist.

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260912123500_narrow_project_configuration_fanout.rb

# The previous migration copied the workspace's settings to every project. For
# most columns that is right: each project starts where the workspace was and
# diverges from there. For the ones that make outbound calls it is wrong — one
# GitHub repo copied onto thirteen projects means thirteen pollers on the same
# repository and thirteen AI reviews of the same pull request.
#
# Those settings go to the project the integration was actually about: the
# workspace's single Jira project. Where that is ambiguous this migration
# changes nothing, because a person can answer it in Configuration and a
# migration cannot.
class NarrowProjectConfigurationFanout < ActiveRecord::Migration[8.1]
  NARROWED = %i[github_repo github_token pr_review_enabled pr_review_prompt
                pr_poll_minutes pr_polled_at figma_read_enabled].freeze

  def up
    Project.reset_column_information
    Workspace.reset_column_information
    defaults = Project.column_defaults

    say_with_time "narrowing per-project integration settings to one project each" do
      Workspace.find_each do |workspace|
        candidates = workspace.projects.where(external_type: "jira")
        next unless candidates.count == 1

        primary = candidates.first
        workspace.projects.where.not(id: primary.id).find_each do |project|
          # Only take back what the backfill put there. Anything a person has
          # since set for this project is theirs.
          cleared = NARROWED.filter_map do |column|
            copied = workspace.read_attribute(column)
            next if copied.nil?
            next unless project.read_attribute(column) == copied

            [ column, defaults[column.to_s] ]
          end.to_h

          project.update_columns(cleared) if cleared.any?
        end
      end
    end
  end

  # Forward-only: restoring a value we deliberately removed would recreate the
  # fan-out it exists to undo.
  def down; end
end
```

`pr_review_enabled` and `figma_read_enabled` are NOT NULL with default `false`, so writing
the column default is what "stop polling" means for them; `github_repo` and `github_token`
are nullable and their default is nil. Confirm both claims against `db/schema.rb` before
you trust the `defaults` lookup, and if any NARROWED column's default is not what you want
written, say so rather than special-casing it silently.

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/migrations/narrow_project_configuration_fanout_test.rb`
Expected: PASS, 4 runs

- [ ] **Step 5: Migrate and commit**

```bash
bin/rails db:migrate
git add db/migrate/20260912123500_narrow_project_configuration_fanout.rb db/schema.rb \
  test/migrations/narrow_project_configuration_fanout_test.rb
git commit -m "fix: integration settings land on one project, not on every project in the workspace"
```

---

### Task 11c: PR review and the AI jobs act on the project they were given

Task 11 moved PR review onto the project. Two things it depends on stayed workspace-shaped,
and both were found by the Task 11 implementer reading past its own brief:

1. **`pr_reviews` is keyed on the workspace.** The table carries a unique index on
   `[workspace_id, pr_number]`. With PR review per project, two enabled projects in one
   workspace collide on any pull-request number they happen to share: the second project's
   PR is skipped permanently, or a follow-up comment is posted against the wrong repository.
   Task 11b makes exactly one project per workspace enabled on the day this ships, so the
   collision is latent — and the first person to switch PR review on for a second project
   trips it with no error anywhere.
2. **Five AI jobs chdir into one hard-coded checkout.** `PrReviewJob`, `AlertRuleRunJob`,
   `BugAttributionJob`, `AutoEstimateJob` and `BackfillDeliveredEstimatesJob` each define
   `CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))`
   and pass it to `ClaudeCliService`. Every one of them already holds the project it is
   working on, and `Project#repo_checkout_path` already resolves the right directory per
   project — including the grandfathered `~/work/elvium` for the legacy project. So a second
   client's pull request would today be reviewed against Elvium's source tree, by a job that
   knows perfectly well which project it is reviewing.

**Files:**
- Create: `db/migrate/20260912125000_add_project_id_to_pr_reviews.rb`
- Modify: `app/models/pr_review.rb`, `app/models/project.rb`, `app/jobs/pr_review_job.rb`, `app/jobs/pr_review_check_job.rb`, `app/jobs/alert_rule_run_job.rb`, `app/jobs/bug_attribution_job.rb`, `app/jobs/auto_estimate_job.rb`, `app/jobs/backfill_delivered_estimates_job.rb`
- Test: `test/jobs/pr_review_check_job_test.rb` (extended), `test/jobs/codebase_path_test.rb` (new)

**Interfaces:**
- Consumes: `Project#repo_checkout_path` (already in the tree), the per-project PR-review columns from Task 10, the project-scoped jobs from Task 11.
- Produces: `PrReview#project`, `Project#pr_reviews`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/jobs/codebase_path_test.rb
require "test_helper"

# Five jobs used to chdir into one machine-wide checkout. Each of them is
# handed a project, and each project resolves its own directory — so a second
# client's code is never read out of the first client's tree.
class CodebasePathTest < ActiveSupport::TestCase
  JOBS = [ PrReviewJob, AlertRuleRunJob, BugAttributionJob, AutoEstimateJob,
           BackfillDeliveredEstimatesJob ].freeze

  test "no job carries its own machine-wide codebase constant any more" do
    JOBS.each do |job|
      assert_not job.const_defined?(:CODEBASE_PATH, false),
                 "#{job} still defines CODEBASE_PATH"
    end
  end

  test "a project resolves its own checkout" do
    project = projects(:jira_project)
    project.update_columns(workspace_dir: "/tmp/clients/9/9", github_repo: "acme/partner-portal")

    assert_equal "/tmp/clients/9/9/partner-portal", project.repo_checkout_path
  end
end
```

```ruby
# test/jobs/pr_review_check_job_test.rb — add this case

  # The table used to be unique on [workspace_id, pr_number]. Two projects in
  # one workspace reviewing a PR with the same number is the ordinary case once
  # PR review is per project, and the loser used to be skipped in silence.
  test "two projects in one workspace can each review their own PR number" do
    first = projects(:jira_project)
    second = projects(:plain_project)

    one = PrReview.create!(project: first, workspace: first.workspace, pr_number: 42)
    two = PrReview.create!(project: second, workspace: second.workspace, pr_number: 42)

    assert_not_equal one.id, two.id
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/jobs/codebase_path_test.rb test/jobs/pr_review_check_job_test.rb`
Expected: the constant case fails (all five are still defined), and the two-projects case
fails on the unique index.

- [ ] **Step 3: Key pr_reviews on the project**

```ruby
# db/migrate/20260912125000_add_project_id_to_pr_reviews.rb

# A PR review belongs to the project whose repository the pull request is in.
# The workspace column stays: it is what the Process page still groups by, and
# Task 13 is explicit that pr_reviews does not move off the workspace.
class AddProjectIdToPrReviews < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:pr_reviews, :project_id)
      add_column :pr_reviews, :project_id, :bigint
      add_index :pr_reviews, :project_id
    end

    PrReview.reset_column_information

    # Every existing row was written by the one workspace-wide reviewer, so it
    # belongs to whichever project now carries that workspace's repository.
    PrReview.where(project_id: nil).find_each do |review|
      owner = Project.where(workspace_id: review.workspace_id)
                     .where(pr_review_enabled: true).order(:id).first ||
              Project.where(workspace_id: review.workspace_id).order(:id).first
      review.update_columns(project_id: owner.id) if owner
    end

    # The old uniqueness was the bug: swap it for the project-scoped one, and
    # keep a plain index on the workspace for the Process page's grouping.
    if index_exists?(:pr_reviews, [ :workspace_id, :pr_number ], unique: true)
      remove_index :pr_reviews, column: [ :workspace_id, :pr_number ]
    end
    unless index_exists?(:pr_reviews, [ :project_id, :pr_number ], unique: true)
      add_index :pr_reviews, [ :project_id, :pr_number ], unique: true
    end
  end

  def down
    if index_exists?(:pr_reviews, [ :project_id, :pr_number ], unique: true)
      remove_index :pr_reviews, column: [ :project_id, :pr_number ]
    end
    unless index_exists?(:pr_reviews, [ :workspace_id, :pr_number ], unique: true)
      add_index :pr_reviews, [ :workspace_id, :pr_number ], unique: true
    end
    remove_column :pr_reviews, :project_id if column_exists?(:pr_reviews, :project_id)
  end
end
```

`belongs_to :project, optional: true` on `PrReview`, `has_many :pr_reviews, dependent: :nullify`
on `Project`. Then find every `find_or_initialize_by` / `find_by` on `PrReview` keyed by
workspace and pr_number — grep `PrReview` across `app/` — and key it by project and
pr_number instead, keeping `workspace_id` populated on create. Report every call site you
changed.

**The down migration can only restore the old unique index if the rows still satisfy it.**
If two projects in one workspace have reviewed the same PR number by then, it raises. Say
so in a comment rather than silently de-duplicating someone's review history.

- [ ] **Step 4: Each job uses the checkout of the project it was given**

Delete `CODEBASE_PATH` from all five jobs and pass `project.repo_checkout_path` to
`ClaudeCliService` instead. Each job already has the project in hand:

| Job | Where the project comes from |
| --- | --- |
| `PrReviewJob` | the `project` local already used at `:189` for the MCP config |
| `PrReviewCheckJob` | the project it iterates (Task 11) |
| `AlertRuleRunJob` | the `project` local already used at `:86` |
| `BugAttributionJob` | `Project.find_by(id: project_id)` at `:33` |
| `AutoEstimateJob` | `task.project` — it already reaches for `task.project.workspace` at `:31` |
| `BackfillDeliveredEstimatesJob` | `Project.find_by(id: project_id)` at `:23` |

Read each site before changing it. If any job turns out NOT to hold a project where it
builds the service, stop and report rather than threading one through — that would be a
design change, not this fix.

`PR_REVIEW_CODEBASE_PATH` is read nowhere else after this. Grep for it, and if it is set in
`.env.production` leave the variable alone — removing it from the server is a deploy step,
not a code change. Note it in your report.

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/jobs/codebase_path_test.rb test/jobs/pr_review_check_job_test.rb test/jobs/pr_review_job_test.rb test/jobs/alert_rule_run_job_test.rb test/jobs/bug_attribution_job_test.rb test/jobs/auto_estimate_job_test.rb`
Expected: PASS. Any of those files that does not exist, skip and say so. Also grep `test/`
for `CODEBASE_PATH` and `PR_REVIEW_CODEBASE_PATH` and run every file that hits.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260912125000_add_project_id_to_pr_reviews.rb db/schema.rb \
  app/models/pr_review.rb app/models/project.rb app/jobs test/jobs
git commit -m "fix: a PR review is keyed on its project, and each AI job reads that project's checkout"
```

---

### Task 12: Discord webhooks belong to a project

**Files:**
- Create: `db/migrate/20260912124000_add_project_id_to_discord_webhooks.rb`
- Modify: `app/models/discord_webhook.rb`, `app/models/project.rb`, `app/controllers/workshop/discord_webhooks_controller.rb`, `app/views/workshop/configuration/_manage_discord.html.erb`
- Test: `test/controllers/workshop/discord_webhooks_controller_test.rb` (extended)

**Interfaces:**
- Consumes: nothing from earlier phases.
- Produces: `Project#discord_webhooks` association; `DiscordWebhook#project`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260912124000_add_project_id_to_discord_webhooks.rb
class AddProjectIdToDiscordWebhooks < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:discord_webhooks, :project_id)
      add_column :discord_webhooks, :project_id, :bigint
      add_index :discord_webhooks, :project_id
    end

    # A webhook goes to the project whose alert rules actually post to it. Only
    # when nothing references it is there no better answer than the first
    # project in its workspace. Guessing by workspace order would otherwise be
    # able to hand a webhook to a project whose alert rules then could not see
    # it in their own dropdown.
    DiscordWebhook.reset_column_information
    DiscordWebhook.where(project_id: nil).find_each do |webhook|
      used_by = AlertRule.where(discord_webhook_id: webhook.id)
                         .group(:project_id).order(Arel.sql("COUNT(*) DESC")).limit(1).pluck(:project_id).first
      fallback = Project.where(workspace_id: webhook.workspace_id).order(:id).first&.id
      target = used_by || fallback
      webhook.update_columns(project_id: target) if target
    end
  end

  def down
    remove_index :discord_webhooks, :project_id if index_exists?(:discord_webhooks, :project_id)
    remove_column :discord_webhooks, :project_id if column_exists?(:discord_webhooks, :project_id)
  end
end
```

- [ ] **Step 2: Wire the association**

```ruby
# app/models/discord_webhook.rb
  belongs_to :project, optional: true
```

```ruby
# app/models/project.rb — with the other has_many declarations
  has_many :discord_webhooks, dependent: :nullify
```

`dependent: :nullify` rather than `:destroy`: a webhook that outlives its project is a stray row, but a deleted webhook is a silently broken alert.

- [ ] **Step 3: Scope the controller and the view**

In `app/controllers/workshop/discord_webhooks_controller.rb`, replace `current_workspace.discord_webhooks` with `current_workshop_project.discord_webhooks` throughout. In `app/controllers/workshop/configuration_controller.rb`, change `load_integrations_tab` to read `@discord_webhooks = current_workshop_project&.discord_webhooks&.order(:channel_name) || DiscordWebhook.none`.

- [ ] **Step 3b: Check no alert rule is left pointing at an invisible webhook**

An `AlertRule` belongs to a project and names a `discord_webhook`. Once webhooks are
per project, a rule on project A holding a webhook that now belongs to project B would
render a dropdown that does not contain its own current value — and saving the form would
silently blank it. Step 1's backfill makes that impossible for existing rows, so this step
only has to prove it and keep it that way:

```ruby
# test/models/discord_webhook_test.rb — new file
require "test_helper"

# A rule can only post to a webhook on its own project. If this ever stops
# being true, the alert form silently drops the channel it was posting to.
class DiscordWebhookTest < ActiveSupport::TestCase
  test "no alert rule points at a webhook belonging to another project" do
    mismatched = AlertRule.joins(:discord_webhook)
                          .where.not(discord_webhooks: { project_id: nil })
                          .where("discord_webhooks.project_id != alert_rules.project_id")

    assert_empty mismatched.to_a
  end
end
```

Then scope the webhook options in the alert-rule form to
`current_workshop_project.discord_webhooks` — find the form by grepping for
`discord_webhook_id` under `app/views`, and report what you changed.

- [ ] **Step 4: Run the test**

Run: `bin/rails db:migrate && bin/rails test test/controllers/workshop/discord_webhooks_controller_test.rb test/models/discord_webhook_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260912124000_add_project_id_to_discord_webhooks.rb db/schema.rb app/models app/controllers
git commit -m "feat: a Discord webhook belongs to a project, not to the whole workspace"
```

---

### Task 13: Configuration edits the project

**Files:**
- Create: `app/models/concerns/estimation_settings.rb`
- Modify: `app/models/project.rb`, `app/models/workspace.rb`, `app/jobs/auto_estimate_job.rb`, `app/controllers/workshop/configuration_controller.rb`, `app/controllers/workshop/process_controller.rb`, `app/controllers/workspace_settings_controller.rb`, `app/helpers/clar_helper.rb`, `app/views/workspace_settings/show.html.erb`, `app/views/workshop/configuration/_integrations_tab.html.erb`, `_ai_tab.html.erb`, `_manage_github.html.erb`, `_manage_figma.html.erb`, `app/views/workshop/process/_estimate_tab.html.erb`
- Test: `test/controllers/workshop/configuration_controller_test.rb` (extended), `test/helpers/clar_helper_integration_chips_test.rb` (rewritten), `test/models/estimation_settings_test.rb` (new)

**Interfaces:**
- Consumes: Tasks 10 through 12.
- Produces: no new interface. Every form on the page posts to the project.

- [ ] **Step 0: Move the estimation reader, not just the column**

Task 10 copied `estimation_field_names` and `estimation_trigger` onto `projects`, but the
code that makes those columns safe to read stayed on `Workspace`:

- `Workspace#estimation_field_names` overrides the attribute to normalize it. MySQL hands a
  `:json` column back as a raw JSON **String** where PostgreSQL parses it to an Array, and
  MySQL cannot carry a JSON column default at all — so the `["AI estimation"]` default also
  lives in that method, not in the schema.
- Without it, `Project#estimation_field_names` returns `nil` for the common production case
  (the AI tab deletes the key when no box is ticked), and `@estimation_field_names.each` in
  `workshop/process/_estimate_tab.html.erb` is a 500. On MySQL it returns a String and
  `names - Workspace::ESTIMATION_FIELD_OPTIONS` in `_ai_tab.html.erb` is a 500.
- `AutoEstimateJob:74` still reads `workspace.estimation_field_names`, a column Task 18
  drops.

Extract the behaviour into a concern both models include, rather than copying thirty lines:

```ruby
# app/models/concerns/estimation_settings.rb

# The AI estimation settings, shared while they live on both the workspace and
# the project. MySQL (production) carries no JSON column default and hands a
# :json column back as a raw String where PostgreSQL parses it to an Array, so
# the default and the normalization both have to live in Ruby — and in exactly
# one place, or the two models disagree about what "no fields chosen" means.
module EstimationSettings
  extend ActiveSupport::Concern

  DEFAULT_ESTIMATION_FIELD_NAME = "AI estimation".freeze

  ESTIMATION_FIELD_OPTIONS = [
    "AI estimation",
    "Story point estimate",
    "T-shirt size",
    "Confidence (1–5)"
  ].freeze

  ESTIMATION_TRIGGERS = {
    "sprint" => "Added to a Development sprint",
    "status" => "Status changes to “Ready for dev”",
    "briefed" => "AI actions = Briefed",
    "manual" => "Manually, on request"
  }.freeze

  def estimation_field_names
    value = super
    if value.is_a?(String)
      value = value.blank? ? nil : (JSON.parse(value) rescue value)
    end
    Array(value).reject { |v| v.nil? || v == "" }.presence || [ DEFAULT_ESTIMATION_FIELD_NAME ]
  end

  def estimation_trigger_label
    ESTIMATION_TRIGGERS[estimation_trigger] || estimation_trigger
  end
end
```

Include it in `Project` and in `Workspace`, and delete from `app/models/workspace.rb` the
now-duplicated `ESTIMATION_FIELD_OPTIONS`, `ESTIMATION_TRIGGERS`,
`estimation_field_names`, `estimation_trigger_label` and the private
`normalize_field_names`. Read the file first: `DEFAULT_ESTIMATION_FIELD_NAME` is declared
there too, and other code may reference `Workspace::DEFAULT_ESTIMATION_FIELD_NAME` — grep
before deleting, and keep a reference working if anything needs it (a constant assigned to
the concern's is fine).

Point `AutoEstimateJob` at the project. Read it first to see what it already has in hand:
if it holds a task or a project, use that; if it only holds a workspace, take the project
from the record it is estimating. Say in your report which it was.

In the two views, `Workspace::ESTIMATION_FIELD_OPTIONS` and `Workspace::ESTIMATION_TRIGGERS`
become `EstimationSettings::ESTIMATION_FIELD_OPTIONS` and `::ESTIMATION_TRIGGERS`.

```ruby
# test/models/estimation_settings_test.rb
require "test_helper"

# The two shapes production actually returns: MySQL's raw JSON string, and the
# NULL that the AI tab writes whenever every box is unticked.
class EstimationSettingsTest < ActiveSupport::TestCase
  test "a raw JSON string normalizes to an array" do
    project = projects(:jira_project)
    project.update_columns(estimation_field_names: nil)
    project.estimation_field_names = nil
    project.write_attribute(:estimation_field_names, '["Story point estimate"]')

    assert_equal [ "Story point estimate" ], project.estimation_field_names
  end

  test "nothing chosen falls back to the one default field" do
    project = projects(:jira_project)
    project.update_columns(estimation_field_names: nil)

    assert_equal [ EstimationSettings::DEFAULT_ESTIMATION_FIELD_NAME ],
                 project.reload.estimation_field_names
  end

  test "the workspace still answers the same way while it holds the column" do
    workspaces(:one).update_columns(estimation_field_names: nil)

    assert_equal [ EstimationSettings::DEFAULT_ESTIMATION_FIELD_NAME ],
                 workspaces(:one).reload.estimation_field_names
  end
end
```

The first case writes through `write_attribute` to simulate what MySQL hands back on
PostgreSQL. If the `:json` attribute type casts it before the override sees it, say so and
assert the same thing the way the adapter actually allows — do not delete the case.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/configuration_controller_test.rb — add these

  test "the AI tab saves onto the project, not the workspace" do
    sign_in_as(users(:one))
    workspace_memberships(:one_owner).update!(workspace_admin: true)

    patch workshop_configuration_path, params: {
      tab: "ai", project: { pr_poll_minutes: 21, pr_review_prompt: "Be brief." }
    }

    assert_equal 21, projects(:jira_project).reload.pr_poll_minutes
    assert_equal "Be brief.", projects(:jira_project).pr_review_prompt
  end

  test "a blank secret preserves the one already stored" do
    sign_in_as(users(:one))
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    projects(:jira_project).update!(github_token: "keep-me")

    patch workshop_configuration_path, params: {
      tab: "integrations", integration: "github", project: { github_repo: "acme/new", github_token: "" }
    }

    assert_equal "keep-me", projects(:jira_project).reload.github_token
    assert_equal "acme/new", projects(:jira_project).github_repo
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: FAIL — the update still writes to `current_workspace`

- [ ] **Step 3: Rewrite the update path**

```ruby
# app/controllers/workshop/configuration_controller.rb

  AI_FIELDS = %i[
    pr_review_prompt pr_poll_minutes pr_review_enabled
    estimation_trigger estimation_status_trigger figma_read_enabled anthropic_api_key
  ].freeze

  INTEGRATION_FIELDS = {
    "jira" => %i[jira_site jira_email jira_api_token],
    "github" => %i[github_repo github_token pr_review_enabled],
    "figma" => %i[figma_token figma_read_enabled]
  }.freeze

  # A blank secret means "leave it alone", never "erase it" — the forms render
  # secrets as empty fields, so submitting the page untouched must not wipe the
  # keys.
  SECRETS = %i[jira_api_token github_token figma_token anthropic_api_key].freeze

  def update
    tab = requested_tab
    return head :forbidden unless tab_permitted?(tab)

    project = current_workshop_project
    return redirect_with("No project selected.", tab) unless project

    case tab
    when "ai" then save_project_fields(project, AI_FIELDS, "AI settings saved")
    when "integrations" then save_integration(project)
    when "briefing" then save_briefing(project)
    end

    redirect_to workshop_configuration_path(tab: tab)
  end

  private

  def save_integration(project)
    fields = INTEGRATION_FIELDS.fetch(params[:integration].to_s, [])
    save_project_fields(project, fields, "Integration settings saved")
    ProjectMcpConfig.write!(project) if project.workspace_dir.present?
  end

  def save_project_fields(project, fields, notice)
    attrs = params.require(:project).permit(*fields, estimation_field_names: []).to_h.symbolize_keys
    SECRETS.each { |secret| attrs.delete(secret) if attrs[secret].blank? }

    names = Array(attrs[:estimation_field_names]).map { |n| n.to_s.strip }.reject(&:blank?)
    names.any? ? attrs[:estimation_field_names] = names : attrs.delete(:estimation_field_names)

    if project.update(attrs)
      flash[:clar_toast] = notice
    else
      flash[:alert] = project.errors.full_messages.to_sentence
    end
  end

  def save_briefing(project)
    personas = params.dig(:project, :briefing_personas).to_s.strip.presence
    project.update(briefing_personas: personas)
    flash[:clar_toast] = "Briefing settings saved"
  end

  def redirect_with(alert, tab)
    flash[:alert] = alert
    redirect_to workshop_configuration_path(tab: tab)
  end
```

Also change `test_github` and `verify_jira_fields` to write onto `current_workshop_project` instead of `current_workspace`, and change the four `load_*_tab` methods to read from the project.

- [ ] **Step 4: Change the form scopes in the views**

In the four partials, change every `form_with model: current_workspace` / `f.fields_for :workspace` to the project, and every `current_workspace.<setting>` read to `current_workshop_project.<setting>`. Add a Figma token field to `_manage_figma.html.erb` in the same shape as the GitHub token field, rendered blank with the placeholder `Leave blank to keep the current token`.

- [ ] **Step 5: Move the last two workspace readers**

Two places outside Configuration still read settings that now live on the project. Both break the moment Task 18 drops the columns, so they move here.

In `app/controllers/workshop/process_controller.rb:16`, change
`@poll_minutes = [ 7, current_workspace.pr_poll_minutes ].max` to read
`current_workshop_project&.pr_poll_minutes || 7`. Leave
`current_workspace.pr_reviews` alone — `pr_reviews` still belongs to the
workspace and that table is not moving.

In `app/controllers/workspace_settings_controller.rb`, delete `test_github` and
its route, and remove the GitHub section from
`app/views/workspace_settings/show.html.erb`. GitHub is per-project now, and
Configuration › Integrations is where it is edited; a second form writing a
column that no longer exists is worse than no form. Workspace Settings keeps
its name, the Workshop and Clients feature toggles, and the Discord channel
used by the HR time-logging reminders.

- [ ] **Step 5b: Point the topbar chips at the project**

`ClarHelper#integration_chips` still reads `Current.workspace`'s status columns.
`IntegrationHealthJob` stopped writing those in Task 11, so without this the chips freeze
at whatever they said the day release one shipped — the exact failure the chips were built
to prevent. The chips are a Workshop topbar element and the Workshop is per project now, so
every one of the four reads the project:

```ruby
  def integration_chips
    project = current_workshop_project
    return [] unless project

    [
      chip("Jira", configured: project.jira_connected?,
                   ok: project.jira_status_ok, error: project.jira_status_error),
      chip("GitHub", configured: project.github_repo.present?,
                     ok: project.github_status_ok, error: project.github_status_error),
      chip("Discord", configured: project.discord_webhooks.any?, ok: nil, error: nil,
                      unchecked_note: "not health-checked"),
      chip("Figma", configured: project.figma_read_enabled?,
                    ok: project.figma_status_ok, error: project.figma_status_error)
    ]
  end
```

Returning `[]` with no project is deliberate: the alternative is four grey chips claiming
nothing is connected, on a screen where nothing is selected. Read
`app/views/layouts/_clar_topbar.html.erb:57` and confirm an empty array renders nothing
rather than an empty wrapper.

Also repoint `github_connection_problem?` in `app/controllers/concerns/authorization.rb` —
Task 5 deliberately left it on the workspace with a comment saying Task 11 would move it,
and Task 11 moved the writer without the reader. It becomes:

```ruby
  def github_connection_problem?
    project = current_workshop_project
    project&.github_token.present? && project.github_status_ok == false
  end
```

`test/helpers/clar_helper_integration_chips_test.rb` **already exists** with five cases, and
every one of them breaks here: they set up `workspaces(:one)` and stub
`current_workshop_project` to nil, which under the new helper means no chips at all. Rewrite
it against a project and **keep all five cases** — each encodes a lesson worth keeping:

1. a working integration is on and not broken
2. a failing integration is broken and says why on hover (this is the expired-Figma-token
   case the chips were built for)
3. an integration nobody configured is neither on nor broken
4. configured but never checked reads as connected, not as broken
5. Discord admits it is not health-checked

Stub `current_workshop_project` to return `projects(:jira_project)` instead of nil, move the
status columns onto that project, and for case 5 give the project a `discord_webhook` rather
than setting the workspace's `discord_channel_id`. Add a sixth case for the new branch: with
no project selected the helper returns an empty list rather than four grey chips.
Build the chips through the helper; do not reimplement `chip`.

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/controllers/workshop/configuration_controller_test.rb test/controllers/workspace_settings_controller_test.rb test/helpers/clar_helper_integration_chips_test.rb test/models/estimation_settings_test.rb`
Expected: PASS. If the workspace-settings test asserts on the GitHub section, delete those cases — the section is gone by design.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/workshop app/controllers/workspace_settings_controller.rb \
  app/controllers/concerns/authorization.rb app/helpers/clar_helper.rb \
  app/models/concerns/estimation_settings.rb app/models/project.rb app/models/workspace.rb \
  app/jobs/auto_estimate_job.rb app/views/workshop app/views/workspace_settings config/routes.rb \
  test/controllers test/helpers test/models/estimation_settings_test.rb
git commit -m "feat: Configuration reads and writes the project it is showing"
```

---

## Phase D — managing users in a project

### Task 14: The Users grid

**Files:**
- Create: `app/controllers/workshop/project_members_controller.rb`, `app/views/workshop/configuration/_user_row.html.erb`, `app/javascript/controllers/permission_switch_controller.js`
- Modify: `app/views/workshop/configuration/_users_tab.html.erb`, `config/routes.rb`, `app/controllers/workshop/configuration_controller.rb`
- Test: `test/controllers/workshop/project_members_controller_test.rb`

**Interfaces:**
- Consumes: `ProjectMembership#apply_preset`, `#role_label`, `permission_role_badge`, `require_permission!(:configuration)`.
- Produces: routes `workshop_project_members_path` (POST), `workshop_project_member_path(id)` (PATCH, DELETE). PATCH accepts `{ permission: <name>, value: "1"|"0" }` and renders the updated row as a Turbo Stream.
- Produces: `PermissionPreset::LABELS` and `PermissionPreset::DESCRIPTIONS`, the only place in the product where a permission is named and explained. Task 15 and Task 19 both read them.

- [ ] **Step 0: Name and explain the six switches, once**

`briefing_config.to_s.humanize` reads "Briefing config", and the product calls it
**Briefing Configuration** everywhere. More importantly, a column of six switches with
one-word headers tells nobody what they do. Both the name and the explanation belong in
one place, because the grid, the invite dialog, the locked tabs and the profile page all
have to say the same thing.

Add to `app/models/permission_preset.rb`, below `PERMISSIONS`:

```ruby
  # The display name of each switch. Not `humanize` — the product calls
  # briefing_config "Briefing Configuration", and that wording is the user's.
  LABELS = {
    automations: "Automations",
    tasks: "Tasks",
    reporting: "Reporting",
    pricing: "Pricing",
    briefing_config: "Briefing Configuration",
    configuration: "Configuration"
  }.freeze

  # What each switch actually unlocks, in the words of the person reading the
  # screen: what they can reach, and what they can change there. This is the
  # only copy the product has for its own permissions — the Users grid, the
  # invite dialog, the locked Configuration tabs and the profile page all read
  # it, so changing a sentence here changes it everywhere it is explained.
  DESCRIPTIONS = {
    automations: "See and run the AI agents and alerts, and edit their prompts.",
    tasks: "Open the task board, read tickets and work on their briefs.",
    reporting: "Open Reporting: delivered work, velocity and time spent.",
    pricing: "See money — hourly rates, cost and revenue wherever they appear.",
    briefing_config: "Edit the Briefing tab: ticket statuses, Jira fields and the brief template.",
    configuration: "Edit integration keys and AI settings, and manage who is on this project."
  }.freeze

  def self.label(permission)
    LABELS.fetch(permission.to_sym)
  end

  def self.description(permission)
    DESCRIPTIONS.fetch(permission.to_sym)
  end
```

Add to `test/models/permission_preset_test.rb`:

```ruby
  # A switch nobody can explain is a switch nobody should ship. If a seventh
  # permission is ever added, this fails until it has a name and a sentence.
  test "every permission has a name and an explanation" do
    PermissionPreset::PERMISSIONS.each do |permission|
      assert PermissionPreset.label(permission).present?, "#{permission} has no label"
      assert PermissionPreset.description(permission).present?, "#{permission} has no description"
    end

    assert_equal "Briefing Configuration", PermissionPreset.label(:briefing_config)
  end
```

Run: `bin/rails test test/models/permission_preset_test.rb` — it must fail on the missing
`label` method before you add the constants.


- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/project_members_controller_test.rb
require "test_helper"

# The switches are the product. Everything else on this screen is a reading of
# them, so the endpoint that flips one has to be exact about who may call it.
class Workshop::ProjectMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @membership = project_memberships(:two_elvium)
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))
  end

  test "flipping a switch saves it and reports the new role name" do
    @membership.update!(PermissionPreset.attributes_for("Project Manager"))

    patch workshop_project_member_path(@membership),
          params: { permission: "briefing_config", value: "1" }, as: :turbo_stream

    assert_response :success
    assert @membership.reload.briefing_config
    assert_equal "Product Owner", @membership.role_label
  end

  test "an unknown switch is refused" do
    patch workshop_project_member_path(@membership),
          params: { permission: "launch_missiles", value: "1" }, as: :turbo_stream

    assert_response :unprocessable_entity
  end

  test "someone without Configuration cannot flip anyone's switches" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Project Manager"))

    patch workshop_project_member_path(@membership),
          params: { permission: "configuration", value: "1" }, as: :turbo_stream

    assert_response :redirect
    assert_not @membership.reload.configuration
  end

  test "removing a member takes away the project, not the account" do
    assert_difference "ProjectMembership.count", -1 do
      assert_no_difference "User.count" do
        delete workshop_project_member_path(@membership)
      end
    end
  end

  test "a workspace admin cannot be removed from a project" do
    admin_membership = project_memberships(:one_elvium)

    assert_no_difference "ProjectMembership.count" do
      delete workshop_project_member_path(admin_membership)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/workshop/project_members_controller_test.rb`
Expected: FAIL with `NameError: undefined local variable or method 'workshop_project_member_path'`

- [ ] **Step 3: Add the routes**

```ruby
# config/routes.rb — inside the existing `namespace :workshop do` block
    resources :project_members, only: [ :create, :update, :destroy ]
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/workshop/project_members_controller.rb

# The Users grid in Configuration. Managing who is on a project, and what they
# may do there, costs the Configuration permission — the same one that guards
# the keys, because the two are the same kind of power.
class Workshop::ProjectMembersController < Workshop::BaseController
  # dom_id, so the Turbo Stream replaces the same node the row rendered under.
  include ActionView::RecordIdentifier

  before_action { require_permission!(:configuration) }
  before_action :set_membership, only: %i[update destroy]

  # #create is added in Task 15, together with the dialogs that post to it.

  def update
    permission = params[:permission].to_s.to_sym
    return head :unprocessable_entity unless PermissionPreset::PERMISSIONS.include?(permission)

    @membership.update!(permission => params[:value] == "1")
    render turbo_stream: turbo_stream.replace(
      dom_id(@membership), partial: "workshop/configuration/user_row", locals: { membership: @membership }
    )
  end

  def destroy
    # A workspace admin's access comes from the flag, so removing the row would
    # change nothing. Refusing is honest; pretending is not.
    if @membership.user.workspace_admin?(current_workspace)
      return redirect_to workshop_configuration_path(tab: "users"),
                         alert: "An administrator's access does not come from this project."
    end

    name = @membership.user.name
    @membership.destroy
    redirect_to workshop_configuration_path(tab: "users"),
                flash: { clar_toast: "#{name} removed from #{current_workshop_project.name}." },
                status: :see_other
  end

  private

  def set_membership
    @membership = current_workshop_project.project_memberships.find(params[:id])
  end
end
```

- [ ] **Step 5: Write the row partial**

```erb
<%# app/views/workshop/configuration/_user_row.html.erb %>
<% access = ProjectAccess.new(membership.user, current_workshop_project) %>
<% locked = access.workspace_admin? %>
<% badge_class, badge_label = permission_role_badge(locked ? access : membership) %>
<div id="<%= dom_id(membership) %>"
     class="grid items-center gap-3 py-3 px-5 border-b border-[color:var(--border)]"
     style="grid-template-columns: minmax(200px,1.4fr) 120px repeat(6, minmax(72px,1fr)) 36px">
  <div class="flex items-center gap-3 min-w-0">
    <span class="w-8 h-8 rounded-full flex items-center justify-center text-[11px] font-bold text-white flex-none <%= clar_avatar_bg_class(membership.user.name) %>">
      <%= clar_initials(membership.user.name) %>
    </span>
    <div class="min-w-0">
      <div class="font-semibold text-[13.5px] clar-text-text truncate"><%= membership.user.name %></div>
      <div class="text-[11.5px] clar-text-faint truncate"><%= membership.user.email_address %></div>
    </div>
  </div>

  <span class="clar-badge <%= badge_class %> whitespace-nowrap w-fit"><%= badge_label %></span>

  <%# clar-toggle-sm paints the track, and its on-state is selected from the
      PARENT — so aria-checked lives on the button, not on the span. %>
  <% PermissionPreset::PERMISSIONS.each do |permission| %>
    <div data-controller="permission-switch"
         data-permission-switch-url-value="<%= workshop_project_member_path(membership) %>"
         data-permission-switch-permission-value="<%= permission %>"
         class="clar-tip w-fit"
         data-tip="<%= PermissionPreset.label(permission) %> &mdash; <%= PermissionPreset.description(permission) %>">
      <button type="button" role="switch"
              aria-checked="<%= locked || membership[permission] %>"
              aria-label="<%= PermissionPreset.label(permission) %> for <%= membership.user.name %>: <%= PermissionPreset.description(permission) %>"
              class="flex items-center bg-transparent border-0 p-0 <%= locked ? 'cursor-default opacity-50' : 'cursor-pointer' %>"
              <%= "disabled" if locked %>
              data-action="permission-switch#toggle">
        <span class="clar-toggle-sm"><span class="knob"></span></span>
      </button>
    </div>
  <% end %>

  <% if locked %>
    <span class="clar-tip clar-text-faint opacity-30 flex p-1.5"
          data-tip="An administrator's access does not come from this project">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
    </span>
  <% else %>
    <%= button_to workshop_project_member_path(membership), method: :delete,
          form: { data: { turbo_confirm: "Remove #{membership.user.name} from #{current_workshop_project.name}?" } },
          class: "bg-transparent border-0 cursor-pointer clar-text-faint flex p-1.5 rounded-[7px]",
          aria: { label: "Remove #{membership.user.name}" } do %>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 6: Rewrite the Users tab**

```erb
<%# app/views/workshop/configuration/_users_tab.html.erb %>
<%# One clar-modal scope wraps the header triggers and both dialogs: the
    controller resolves which panel to open from data-clar-modal-id-param. %>
<div class="clar-card p-0 overflow-hidden" data-controller="clar-modal">
  <div class="flex items-center justify-between gap-2.5 py-3.5 px-5 border-b border-[color:var(--border)]">
    <div>
      <span class="font-bold text-[14px] clar-text-text">Users</span>
      <span class="text-[12px] clar-text-faint ml-2">
        <%= pluralize(@members.size, "person") %> in <%= current_workshop_project.name %> &middot; invited separately per project
      </span>
    </div>
    <div class="flex gap-2">
      <button type="button" class="clar-btn" data-action="clar-modal#open"
              data-clar-modal-id-param="add-existing"
              <%= "disabled" if @addable_users.empty? %>>Add from other project</button>
      <button type="button" class="clar-btn clar-btn-primary" data-action="clar-modal#open"
              data-clar-modal-id-param="invite">Invite</button>
    </div>
  </div>

  <div class="overflow-x-auto"><div class="min-w-[980px]">
    <div class="grid items-center gap-3 py-2.5 px-5 border-b border-[color:var(--border)] bg-[color:var(--surface-2)] text-[10.5px] font-bold tracking-[.5px] clar-text-faint"
         style="grid-template-columns: minmax(200px,1.4fr) 120px repeat(6, minmax(72px,1fr)) 36px">
      <span>USER</span><span>ROLE</span>
      <% PermissionPreset::PERMISSIONS.each do |permission| %>
        <%# The header is the first place anyone asks "what is this column?", so
            it carries the explanation rather than only the name. %>
        <span class="clar-tip leading-[1.3] whitespace-pre-line w-fit"
              data-tip="<%= PermissionPreset.description(permission) %>">
          <%= PermissionPreset.label(permission).upcase.sub(" ", "\n") %>
        </span>
      <% end %>
      <span></span>
    </div>

    <%= render partial: "workshop/configuration/user_row", collection: @members, as: :membership %>
  </div></div>

  <%= render "permission_legend" %>
</div>

<%= render "invite_modal" %>
```

**Create `app/views/workshop/configuration/_permission_legend.html.erb` in this same
step.** The grid is six unlabelled toggles unless the screen says what they mean, and this
partial is the sentence-level answer. It takes no locals and reads no instance variable, so
it stays a statement of the rules rather than of one project's state:

```erb
<%# app/views/workshop/configuration/_permission_legend.html.erb %>
<%# What the six switches mean and what the three names add up to. No locals:
    this explains the rules, not one project's state. Task 19 says the same
    thing to the person themselves on the profile page, in that page's own
    design system, from the same two constants. %>
<div class="border-t border-[color:var(--border)] py-4 px-5 grid gap-5 md:grid-cols-2">
  <div>
    <div class="text-[10.5px] font-bold tracking-[.5px] clar-text-faint mb-2">WHAT EACH PERMISSION ALLOWS</div>
    <dl class="space-y-1.5">
      <% PermissionPreset::PERMISSIONS.each do |permission| %>
        <div class="flex gap-2 text-[11.5px] leading-[1.45]">
          <dt class="font-semibold clar-text-text whitespace-nowrap min-w-[130px]"><%= PermissionPreset.label(permission) %></dt>
          <dd class="clar-text-faint"><%= PermissionPreset.description(permission) %></dd>
        </div>
      <% end %>
    </dl>
  </div>

  <div>
    <div class="text-[10.5px] font-bold tracking-[.5px] clar-text-faint mb-2">THE THREE ROLE NAMES</div>
    <dl class="space-y-1.5">
      <% PermissionPreset::PRESETS.each do |label, permissions| %>
        <div class="flex gap-2 text-[11.5px] leading-[1.45]">
          <dt class="font-semibold clar-text-text whitespace-nowrap min-w-[130px]"><%= label %></dt>
          <dd class="clar-text-faint">
            <%= permissions.map { |permission| PermissionPreset.label(permission) }.to_sentence %>
          </dd>
        </div>
      <% end %>
      <div class="flex gap-2 text-[11.5px] leading-[1.45]">
        <dt class="font-semibold clar-text-text whitespace-nowrap min-w-[130px]">Custom</dt>
        <dd class="clar-text-faint">Any other combination. The name follows the switches, so it changes as you flip them.</dd>
      </div>
    </dl>
    <p class="text-[11.5px] clar-text-faint mt-2.5 leading-[1.45]">
      Permissions are set per project, and an invitation is per project too. Workspace
      administrators hold all six everywhere and cannot be removed from a single project.
    </p>
  </div>
</div>
```

**Create `app/views/workshop/configuration/_invite_modal.html.erb` as an empty file in this same step.** Task 15 fills it. Without it every render of the Users tab raises a missing-partial error for the length of one task.

Change `load_users_tab` in the configuration controller to:

```ruby
  def load_users_tab
    project = current_workshop_project
    # No project selected means nothing to list. The method in the tree guards
    # this today and the grid must keep doing so, or the tab 500s on a fresh
    # session before a project has been picked.
    unless project
      @members = []
      @addable_users = User.none
      return
    end

    rows = project.project_memberships.includes(:user).joins(:user).order("users.name")

    # A workspace admin holds every permission here whether or not anyone ever
    # added them to this project. Reading project_memberships alone would leave
    # the person with the most power over the project as the one name missing
    # from its access list, so append them as unsaved rows.
    admins = current_workspace.workspace_memberships.where(workspace_admin: true)
                              .includes(:user).map(&:user)
    missing = admins - rows.map(&:user)
    @members = rows.to_a + missing.map { |user| project.project_memberships.new(user: user) }

    # People who already have an account in this workspace but are not on this
    # project — the "Add from other project" list.
    @addable_users = User.joins(:workspace_memberships)
                         .where(workspace_memberships: { workspace_id: current_workspace.id })
                         .where.not(id: @members.map(&:user_id))
                         .order(:name)
  end
```

Those appended records are UNSAVED, so the row partial must not assume a
persisted id. In `_user_row.html.erb` use
`dom_id(membership.persisted? ? membership : membership.user)`, and render the
delete control only `if membership.persisted?`. An admin's row is locked
anyway, so nothing is lost.

- [ ] **Step 7: Write the switch controller**

```javascript
// app/javascript/controllers/permission_switch_controller.js
import { Controller } from "@hotwired/stimulus"

// Flips one permission and swaps the whole row back in, because the role name
// beside the switches is derived from them and would otherwise go stale.
export default class extends Controller {
  static values = { url: String, permission: String }

  async toggle(event) {
    const button = event.currentTarget
    if (button.disabled) return

    const next = button.getAttribute("aria-checked") !== "true"
    button.disabled = true

    const body = new FormData()
    body.append("permission", this.permissionValue)
    body.append("value", next ? "1" : "0")
    body.append("_method", "patch")

    const response = await fetch(this.urlValue, {
      method: "POST",
      body,
      headers: {
        "Accept": "text/vnd.turbo-stream.html",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
      }
    })

    if (response.ok) {
      Turbo.renderStreamMessage(await response.text())
    } else {
      button.disabled = false
    }
  }
}
```

- [ ] **Step 8: Run the test**

Run: `bin/rails test test/controllers/workshop/project_members_controller_test.rb`
Expected: PASS, 5 runs

- [ ] **Step 9: Build the stylesheet and commit**

```bash
bin/rails tailwindcss:build
git add app/controllers/workshop/project_members_controller.rb app/views/workshop/configuration \
  app/javascript/controllers/permission_switch_controller.js config/routes.rb \
  app/models/permission_preset.rb test/models/permission_preset_test.rb \
  app/assets/builds test/controllers/workshop/project_members_controller_test.rb
git commit -m "feat: Configuration > Users is a grid of per-project permission switches"
```

---

### Task 15: Invite, and add from another project

**Files:**
- Create: `app/views/workshop/configuration/_invite_modal.html.erb`, `app/javascript/controllers/preset_picker_controller.js`
- Modify: `app/controllers/workshop/project_members_controller.rb`
- Test: `test/controllers/workshop/project_members_controller_test.rb` (extended)

**Interfaces:**
- Consumes: `Workshop::ProjectMembersController#create` from Task 14.
- Produces: `create` additionally accepting `{ name:, email_address:, preset: }` to invite a person who has no account yet.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/project_members_controller_test.rb — add these

  test "inviting an unknown address creates the account and the membership" do
    assert_difference [ "User.count", "ProjectMembership.count" ], 1 do
      post workshop_project_members_path, params: {
        name: "Dana Liu", email_address: "dana@acme.io", preset: "Product Owner"
      }
    end

    membership = ProjectMembership.joins(:user).find_by(users: { email_address: "dana@acme.io" })
    assert_equal "Product Owner", membership.role_label
    assert_not membership.user.can_access_time_hr?(workspaces(:one)),
               "a Workshop invitation must not hand out an HR account"
  end

  test "inviting a known address adds them without a second account" do
    assert_no_difference "User.count" do
      post workshop_project_members_path, params: {
        name: "Whatever", email_address: users(:client_user).email_address, preset: "Project Manager"
      }
    end
  end

  test "adding people from another project applies the chosen preset" do
    project_memberships(:client_elvium).destroy!

    post workshop_project_members_path, params: {
      user_ids: [ users(:client_user).id ], preset: "Project Manager"
    }

    membership = ProjectMembership.find_by(user: users(:client_user), project: projects(:jira_project))
    assert_equal "Project Manager", membership.role_label
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/workshop/project_members_controller_test.rb`
Expected: FAIL — `create` handles `user_ids` only

- [ ] **Step 3: Extend create**

```ruby
# app/controllers/workshop/project_members_controller.rb — replace create

  def create
    preset = params[:preset].to_s
    users = params[:email_address].present? ? [ invited_user ] : picked_users
    return redirect_to(workshop_configuration_path(tab: "users"), alert: @error) if @error

    users.compact.each { |user| add_to_project(user, preset) }

    redirect_to workshop_configuration_path(tab: "users"),
                flash: { clar_toast: "#{users.compact.size} added to #{current_workshop_project.name}." }
  end

  private

  def add_to_project(user, preset)
    membership = current_workshop_project.project_memberships.find_or_initialize_by(user: user)
    membership.apply_preset(preset)
    membership.save!
  end

  # People already in this workspace, picked from the chips.
  def picked_users
    User.where(id: Array(params[:user_ids]))
        .joins(:workspace_memberships)
        .where(workspace_memberships: { workspace_id: current_workspace.id })
  end

  # An invitation by address. A Workshop invitation deliberately grants no HR
  # access: the two directories are separate, and a form that quietly set both
  # is the confusion this work exists to remove.
  def invited_user
    address = params[:email_address].to_s.strip.downcase
    user = User.find_by(email_address: address)

    if user.nil?
      password = SecureRandom.base58(24)
      user = User.new(name: params[:name], email_address: address,
                      password: password, password_confirmation: password)
      unless user.save
        @error = user.errors.full_messages.to_sentence
        return nil
      end
    end

    unless user.member_of?(current_workspace)
      current_workspace.workspace_memberships.create!(
        user: user, time_hr_access: false, workspace_admin: false
      )
      InvitationMailer.welcome(user, current_workspace).deliver_later
    end

    user
  end
```

- [ ] **Step 4: Write the modal**

```erb
<%# app/views/workshop/configuration/_invite_modal.html.erb %>
<% presets = PermissionPreset::PRESETS.keys %>

<%# The panel structure the existing clar-modal controller expects: a hidden
    overlay, a .clar-modal panel marked as its target, and an id it resolves
    from the trigger's data-clar-modal-id-param. Not a <dialog>. %>
<div class="clar-modal-overlay hidden" data-clar-modal-target="panel"
     data-clar-modal-panel-id-value="invite" data-action="click->clar-modal#close">
  <div class="clar-modal max-w-[560px]" data-controller="preset-picker"
       data-action="click->clar-modal#stopPropagation">
  <%= form_with url: workshop_project_members_path, method: :post, class: "space-y-4" do %>
    <h2 class="text-[18px] font-bold clar-text-text">Invite to <%= current_workshop_project.name %></h2>

    <label class="block text-[11.5px] font-bold clar-text-faint">NAME</label>
    <%= text_field_tag :name, nil, class: "clar-input w-full", required: true %>

    <label class="block text-[11.5px] font-bold clar-text-faint">EMAIL</label>
    <%= email_field_tag :email_address, nil, class: "clar-input w-full", required: true %>

    <label class="block text-[11.5px] font-bold clar-text-faint">ROLE</label>
    <div class="flex gap-2">
      <% presets.each_with_index do |preset, i| %>
        <button type="button" class="clar-btn flex-1 <%= 'clar-btn-primary' if i == 1 %>"
                data-action="preset-picker#pick" data-preset-picker-name-param="<%= preset %>">
          <%= preset %>
        </button>
      <% end %>
    </div>
    <%= hidden_field_tag :preset, "Product Owner", data: { preset_picker_target: "value" } %>

    <label class="block text-[11.5px] font-bold clar-text-faint">
      PERMISSIONS IN <%= current_workshop_project.name.upcase %>
    </label>
    <div class="clar-card p-0">
      <% PermissionPreset::PERMISSIONS.each_with_index do |permission, i| %>
        <div class="flex items-center justify-between gap-3 py-2.5 px-3 <%= 'border-t border-[color:var(--border)]' if i.positive? %>">
          <%# Every row explains itself. Whoever is inviting is deciding what this
              person will be able to see, and three of six hints is not a decision. %>
          <div>
            <div class="text-[13px] font-semibold clar-text-text"><%= PermissionPreset.label(permission) %></div>
            <div class="text-[11px] clar-text-faint leading-[1.4]"><%= PermissionPreset.description(permission) %></div>
          </div>
          <button type="button" role="switch" aria-checked="false"
                  class="flex items-center bg-transparent border-0 p-0 cursor-pointer"
                  aria-label="<%= PermissionPreset.label(permission) %>: <%= PermissionPreset.description(permission) %>"
                  data-preset-picker-target="switch" data-permission="<%= permission %>"
                  data-action="preset-picker#toggle">
            <span class="clar-toggle-sm"><span class="knob"></span></span>
          </button>
        </div>
      <% end %>
    </div>

    <div class="flex justify-end gap-2">
      <button type="button" class="clar-btn" data-action="clar-modal#close">Cancel</button>
      <%= submit_tag "Send invitation", class: "clar-btn clar-btn-primary" %>
    </div>
  <% end %>
  </div>
</div>
```

Add a second panel in the same file with `data-clar-modal-panel-id-value="add-existing"`, identical except that the name and email fields are replaced by chips of `@addable_users`, each a `check_box_tag "user_ids[]", user.id` inside a `label.clar-chip`.

- [ ] **Step 5: Write the preset picker**

```javascript
// app/javascript/controllers/preset_picker_controller.js
import { Controller } from "@hotwired/stimulus"

// The role buttons are presets and nothing more: they set the switches, and
// the switches are what gets submitted. Touching one afterwards is expected.
const PRESETS = {
  "Project Manager": ["automations", "tasks", "reporting"],
  "Product Owner": ["automations", "tasks", "reporting", "briefing_config"],
  "Administrator": ["automations", "tasks", "reporting", "pricing", "briefing_config", "configuration"]
}

export default class extends Controller {
  static targets = ["switch", "value"]

  connect() { this.apply(this.valueTarget.value) }

  pick(event) {
    this.valueTarget.value = event.params.name
    this.apply(event.params.name)
    this.element.querySelectorAll("[data-preset-picker-name-param]").forEach((button) => {
      button.classList.toggle("clar-btn-primary", button.dataset.presetPickerNameParam === event.params.name)
    })
  }

  apply(preset) {
    const granted = PRESETS[preset] || PRESETS["Project Manager"]
    this.switchTargets.forEach((element) => {
      this.set(element, granted.includes(element.dataset.permission))
    })
  }

  toggle(event) {
    const element = event.currentTarget
    this.set(element, element.getAttribute("aria-checked") !== "true")
  }

  // Each switch carries a hidden input so the form submits the actual state,
  // not the preset the person started from. The painted track reads its
  // on-state off this element's aria-checked, so there is no class to toggle.
  set(element, on) {
    element.setAttribute("aria-checked", on)
    let input = element.nextElementSibling
    if (!input || input.tagName !== "INPUT") {
      input = document.createElement("input")
      input.type = "hidden"
      element.after(input)
    }
    input.name = `permissions[${element.dataset.permission}]`
    input.value = on ? "1" : "0"
  }
}
```

In `add_to_project`, honour those inputs when present, so a tuned set is not overwritten by the preset:

```ruby
  def add_to_project(user, preset)
    membership = current_workshop_project.project_memberships.find_or_initialize_by(user: user)
    membership.apply_preset(preset)
    tuned = params[:permissions]
    if tuned.present?
      PermissionPreset::PERMISSIONS.each do |permission|
        membership[permission] = tuned[permission.to_s] == "1" if tuned.key?(permission.to_s)
      end
    end
    membership.save!
  end
```

- [ ] **Step 6: Run the test**

Run: `bin/rails test test/controllers/workshop/project_members_controller_test.rb`
Expected: PASS, 8 runs

- [ ] **Step 7: Commit**

```bash
bin/rails tailwindcss:build
git add app/views/workshop/configuration app/javascript/controllers/preset_picker_controller.js \
  app/controllers/workshop/project_members_controller.rb app/assets/builds \
  test/controllers/workshop/project_members_controller_test.rb
git commit -m "feat: invite to a project, or add someone who is already on another"
```

---

## Phase E — creating a project

### Task 16: The project switcher

**Files:**
- Modify: `app/views/layouts/_clar_topbar.html.erb`
- Create: `app/views/layouts/_clar_new_project_modal.html.erb`
- Test: `test/controllers/project_switcher_test.rb`

**Interfaces:**
- Consumes: `workshop_projects` from Task 5, `Project#team` from Task 10.
- Produces: the switcher listing each project with its team and repository, and a `New project` entry visible only to a workspace admin.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/project_switcher_test.rb
require "test_helper"

# The switcher swaps everything — keys, automations, people — so it has to say
# which project you are about to swap to, not just its name.
class ProjectSwitcherTest < ActionDispatch::IntegrationTest
  setup do
    projects(:jira_project).update!(team: "Insights team", github_repo: "acme/survey-platform")
    workspace_memberships(:one_owner).update!(workspace_admin: true)
  end

  test "each project shows its team and repository" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_response :success
    assert_match "Insights team", response.body
    assert_match "acme/survey-platform", response.body
  end

  # The switcher is the only screen that lists every project at once, so it is
  # the cheapest place to answer "what am I in each of these?".
  test "each project shows the viewer's own role in it" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_in_as(users(:two))

    get workshop_pipeline_path

    assert_response :success
    assert_match "Product Owner", response.body
  end

  test "only a workspace admin is offered a new project" do
    sign_in_as(users(:one))
    get workshop_pipeline_path
    assert_match "New project", response.body

    workspace_memberships(:one_owner).update!(workspace_admin: false)
    get workshop_pipeline_path
    assert_no_match "New project", response.body
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/project_switcher_test.rb`
Expected: FAIL — the switcher renders names only

- [ ] **Step 3: Rewrite the switcher menu**

The dropdown in the tree already shows the client's name and the Jira key under each
project. Do not drop that to make room for the team and the repo — prefer the new field and
fall back to the old one, so no project's subtitle gets emptier than it is today. The
switcher also gains the viewer's own role name per project: this is the one place where
every project is listed side by side, so it is where "what am I in each of these?" is
cheapest to answer.

In `app/views/layouts/_clar_topbar.html.erb`, replace the body of the project dropdown with:

```erb
<div class="text-[10.5px] font-bold tracking-[.5px] clar-text-faint px-2.5 pt-2.5 pb-1.5">
  SWITCH PROJECT &middot; SWAPS EVERYTHING
</div>

<% workshop_projects.each do |project| %>
  <% badge_class, badge_label = permission_role_badge(ProjectAccess.new(current_user, project)) %>
  <%= button_to switch_workshop_project_path, params: { project_id: project.id },
        class: "flex items-start gap-2.5 w-full py-2 px-2.5 rounded-lg text-left hover:bg-[color:var(--surface-2)]" do %>
    <span class="flex-1 min-w-0">
      <span class="block font-semibold text-[13.5px] clar-text-text truncate"><%= project.name %></span>
      <span class="block text-[11.5px] clar-text-faint truncate">
        <%# The new fields when they are filled in, the old ones while they are not. %>
        <%= [ project.team.presence || project.client&.name,
              project.github_repo.presence || project.external_reference ].compact_blank.join(" · ") %>
      </span>
    </span>
    <span class="clar-badge <%= badge_class %> flex-none whitespace-nowrap"><%= badge_label %></span>
    <% if project == current_workshop_project %>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="clar-text-text flex-none mt-0.5"><path d="M20 6L9 17l-5-5"/></svg>
    <% end %>
  <% end %>
<% end %>

<%# The trigger and the panel must share one clar-modal scope, so wrap this
    block and the render below in a single data-controller="clar-modal". %>
<% if workspace_admin? %>
  <div class="border-t border-[color:var(--border)] mt-1.5 pt-1.5">
    <button type="button" class="flex items-center gap-2.5 w-full py-2 px-2.5 rounded-lg font-semibold text-[13px] clar-text-primary"
            data-action="clar-modal#open" data-clar-modal-id-param="new-project">
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 5v14M5 12h14"/></svg>
      New project
    </button>
  </div>
<% end %>

<%= render "layouts/clar_new_project_modal" if workspace_admin? %>
```

The dropdown panel is `w-[300px]` in the tree. A name, a subtitle, a role badge and a tick
do not fit in 300px — widen it to `w-[360px]` in the same file and check the three-line
case (long project name, long subtitle, "Administrator" badge) does not wrap into a mess.

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/controllers/project_switcher_test.rb`
Expected: the first two tests pass; the third passes once Task 17 supplies the modal partial. Create the partial as an empty file now so the render resolves.

- [ ] **Step 5: Commit**

```bash
bin/rails tailwindcss:build
git add app/views/layouts app/assets/builds test/controllers/project_switcher_test.rb
git commit -m "feat: the project switcher names the team and repo it is swapping to"
```

---

### Task 17: Creating a project

**Files:**
- Create: `app/services/project_creator.rb`, `app/controllers/workshop/projects_controller.rb`
- Modify: `app/views/layouts/_clar_new_project_modal.html.erb`, `config/routes.rb`
- Test: `test/services/project_creator_test.rb`, `test/controllers/workshop/projects_controller_test.rb`

**Interfaces:**
- Consumes: the project configuration columns from Task 10 (read directly as `source[column]`, not through `ProjectCredentials`), `PermissionPreset`, `ProjectMembership#apply_preset`.
- Produces: `ProjectCreator.new(workspace:, attributes:, reuse_from:, member_ids:, preset:).call -> Project`. `reuse_from` is a `Hash{String => Integer}` mapping an integration name (`"jira"`, `"github"`, `"discord"`, `"figma"`, `"ai"`) to a source project id; a missing or blank entry means "set up later".

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/project_creator_test.rb
require "test_helper"

# Creating a project is the one place several decisions land at once: the keys
# it starts with, and who is in it. Keys are COPIED, not linked — see the spec.
# Rotating a token therefore means visiting each project, which is the price of
# deleting a project never becoming a question about another project's keys.
class ProjectCreatorTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @source = projects(:jira_project)
    @source.update!(jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt",
                    github_repo: "acme/source", github_token: "gt", anthropic_api_key: "ak")
  end

  def create(reuse_from: {}, member_ids: [], preset: "Project Manager")
    ProjectCreator.new(
      workspace: @workspace,
      attributes: { name: "Partner Portal", team: "Apps team", github_repo: "acme/partner-portal" },
      reuse_from: reuse_from, member_ids: member_ids, preset: preset
    ).call
  end

  test "copies the chosen keys and leaves the rest blank" do
    project = create(reuse_from: { "jira" => @source.id, "ai" => @source.id })

    assert_equal "acme.atlassian.net", project.jira_site
    assert_equal "jt", project.jira_api_token
    assert_equal "ak", project.anthropic_api_key
    assert_nil project.github_token, "GitHub was set to be configured later"
  end

  test "the form's own repository wins over the copied one" do
    project = create(reuse_from: { "github" => @source.id })

    assert_equal "acme/partner-portal", project.github_repo
    assert_equal "gt", project.github_token
  end

  test "a source project in another workspace is ignored" do
    outsider = Project.create!(name: "Foreign", workspace: workspaces(:two), color: "#3B82F6",
                               jira_api_token: "secret")

    project = create(reuse_from: { "jira" => outsider.id })

    assert_nil project.jira_api_token
  end

  test "chosen people are added with the preset" do
    project = create(member_ids: [ users(:two).id ], preset: "Product Owner")
    membership = project.project_memberships.find_by(user: users(:two))

    assert_equal "Product Owner", membership.role_label
  end

  # `color` is validated present and hex-formatted and the dialog never asks for
  # one, so without this the very first create raises RecordInvalid.
  test "a project gets a colour nobody else in the workspace is using" do
    project = create

    assert_match(/\A#[0-9A-Fa-f]{6}\z/, project.color)
    assert_not_includes @workspace.projects.where.not(id: project.id).pluck(:color), project.color
  end

  test "someone outside the workspace is not added" do
    outsider = User.create!(name: "Outsider", email_address: "out@example.com",
                            password: "x" * 12, password_confirmation: "x" * 12)

    project = create(member_ids: [ outsider.id ])

    assert_empty project.project_memberships.where(user: outsider)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/services/project_creator_test.rb`
Expected: FAIL with `NameError: uninitialized constant ProjectCreator`

- [ ] **Step 3: Write the service**

```ruby
# app/services/project_creator.rb

# Creates a project and settles, in one place, the two things the new-project
# dialog decides: which credentials it starts with, and who is in it.
#
# Credentials are COPIED from the chosen source rather than referenced. A
# reference would make rotating a key a one-move job, but it would also make
# deleting a project a question about other projects' keys, and there is no
# good answer to that question at three in the morning.
class ProjectCreator
  # Which columns each integration owns. The repository is deliberately absent
  # from :github — the dialog asks for it directly, and what the person typed
  # must beat what was copied.
  CREDENTIALS = {
    "jira" => %i[jira_site jira_email jira_api_token],
    "github" => %i[github_token],
    "figma" => %i[figma_token figma_read_enabled],
    "ai" => %i[anthropic_api_key]
  }.freeze

  def initialize(workspace:, attributes:, reuse_from: {}, member_ids: [], preset: "Project Manager")
    @workspace = workspace
    @attributes = attributes
    @reuse_from = reuse_from || {}
    @member_ids = Array(member_ids)
    @preset = preset
  end

  def call
    project = @workspace.projects.new(@attributes)
    project.color ||= next_colour
    copy_credentials_into(project)

    project.save!
    add_members(project)
    project
  end

  private

  # `color` is validated present and hex-formatted, and the dialog does not ask
  # for one — so the service takes the first swatch the workspace is not already
  # using, and cycles once every swatch is taken.
  def next_colour
    taken = @workspace.projects.pluck(:color)
    Project::PROJECT_COLORS.find { |colour| taken.exclude?(colour) } ||
      Project::PROJECT_COLORS[@workspace.projects.count % Project::PROJECT_COLORS.size]
  end

  def copy_credentials_into(project)
    CREDENTIALS.each do |integration, columns|
      source = source_for(integration)
      next unless source

      columns.each do |column|
        # Never overwrite what the dialog collected.
        project[column] = source[column] if project[column].blank?
      end
    end
  end

  # Only a project in the SAME workspace may be a source. Anything else would
  # be one workspace reading another's secrets through a guessed id.
  def source_for(integration)
    id = @reuse_from[integration].presence
    return nil unless id

    @workspace.projects.find_by(id: id)
  end

  def add_members(project)
    users = User.where(id: @member_ids)
                .joins(:workspace_memberships)
                .where(workspace_memberships: { workspace_id: @workspace.id })

    users.find_each do |user|
      project.project_memberships.create!(
        { user: user }.merge(PermissionPreset.attributes_for(@preset))
      )
    end
  end
end
```

`Discord` appears in the dialog but owns no column on the project: its webhooks are rows, added afterwards from Configuration. The dialog's Discord row therefore only ever offers "Set up later", which is honest and needs no branch here.

- [ ] **Step 4: Add the create path**

The existing `ProjectsController` is HR's, and its first `before_action` is
`require_product!(:time_hr)`. Hanging the Workshop's create action there would make
creating a Workshop project require an HR account — the opposite of the split this plan
exists to draw. It gets its own controller in the Workshop namespace, where `require_admin!`
(now `workspace_admin?` — verified at `app/controllers/concerns/authorization.rb:94`) is the
only gate it needs.

```ruby
# config/routes.rb — inside the existing `namespace :workshop do` block
    resources :projects, only: [ :create ]
```

```ruby
# app/controllers/workshop/projects_controller.rb

# The new-project dialog in the project switcher. Creating a project is the
# workspace-wide privilege, not a per-project permission: there is no project
# yet for a permission to sit on.
class Workshop::ProjectsController < Workshop::BaseController
  before_action :require_admin!

  def create
    project = ProjectCreator.new(
      workspace: current_workspace,
      attributes: params.require(:project).permit(:name, :team, :github_repo).merge(external_type: "jira"),
      reuse_from: params[:reuse_from]&.permit!&.to_h,
      member_ids: params[:user_ids],
      preset: params[:preset]
    ).call

    # Land on the new project's Configuration: it has no keys yet, and that is
    # where the person was heading next anyway.
    session[:workshop_project_id] = project.id
    redirect_to workshop_configuration_path(tab: "integrations"),
                flash: { clar_toast: "#{project.name} created." }
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: workshop_pipeline_path,
                  alert: e.record.errors.full_messages.to_sentence
  end
end
```

Read `app/controllers/workshop/base_controller.rb` first and confirm which session key holds
the selected project — the line above assumes `session[:workshop_project_id]`. If it is
named something else, use the real one and say so in your report.

```ruby
# test/controllers/workshop/projects_controller_test.rb
require "test_helper"

# Creating a project is the workspace privilege. Holding every permission on
# one project must not be enough to create another.
class Workshop::ProjectsControllerTest < ActionDispatch::IntegrationTest
  test "a workspace admin creates a project and lands on its configuration" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))

    assert_difference "Project.count", 1 do
      post workshop_projects_path, params: { project: { name: "Partner Portal" } }
    end

    assert_redirected_to workshop_configuration_path(tab: "integrations")
  end

  test "an administrator on one project cannot create another" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Administrator"))
    sign_in_as(users(:one))

    assert_no_difference "Project.count" do
      post workshop_projects_path, params: { project: { name: "Partner Portal" } }
    end
  end
end
```

- [ ] **Step 5: Write the dialog**

```erb
<%# app/views/layouts/_clar_new_project_modal.html.erb %>
<% sources = current_workspace.projects.active.order(:name) %>
<% integrations = [ [ "jira", "Jira Cloud", "API token + site" ],
                    [ "github", "GitHub", "Personal access token" ],
                    [ "discord", "Discord", "Webhook URLs" ],
                    [ "figma", "Figma", "Read token" ],
                    [ "ai", "AI provider", "Claude API key" ] ] %>

<div class="clar-modal-overlay hidden" data-clar-modal-target="panel"
     data-clar-modal-panel-id-value="new-project" data-action="click->clar-modal#close">
  <div class="clar-modal max-w-[620px]" data-action="click->clar-modal#stopPropagation">
  <%= form_with url: workshop_projects_path, method: :post, class: "space-y-4" do |f| %>
    <h2 class="text-[18px] font-bold clar-text-text">New project</h2>
    <p class="text-[13px] clar-text-muted">
      Each project has its own integrations, AI settings, briefing context and users.
      Reuse keys from an existing project where they're the same.
    </p>

    <label class="block text-[11.5px] font-bold clar-text-faint">PROJECT NAME</label>
    <%= text_field_tag "project[name]", nil, class: "clar-input w-full", required: true,
          placeholder: "e.g. Partner Portal" %>

    <div class="grid grid-cols-2 gap-3">
      <div>
        <label class="block text-[11.5px] font-bold clar-text-faint">TEAM</label>
        <%= text_field_tag "project[team]", nil, class: "clar-input w-full", placeholder: "Optional" %>
      </div>
      <div>
        <label class="block text-[11.5px] font-bold clar-text-faint">GITHUB REPO</label>
        <%= text_field_tag "project[github_repo]", nil, class: "clar-input w-full",
              placeholder: "acme/partner-portal" %>
      </div>
    </div>

    <label class="block text-[11.5px] font-bold clar-text-faint">INTEGRATIONS &amp; AI KEYS</label>
    <div class="clar-card p-0">
      <% integrations.each_with_index do |(key, label, hint), i| %>
        <div class="flex items-center justify-between gap-3 py-2.5 px-3 <%= 'border-t border-[color:var(--border)]' if i.positive? %>">
          <div>
            <div class="text-[13px] font-semibold clar-text-text"><%= label %></div>
            <div class="text-[11px] clar-text-faint"><%= hint %></div>
          </div>
          <%# Discord owns no column on the project — its webhooks are added
              afterwards — so it is the one row with nothing to reuse. %>
          <% options = [ [ "Set up later", "" ] ] %>
          <% options += sources.map { |p| [ "Reuse key from #{p.name}", p.id ] } unless key == "discord" %>
          <%= select_tag "reuse_from[#{key}]", options_for_select(options), class: "clar-input w-[230px]" %>
        </div>
      <% end %>
    </div>

    <label class="block text-[11.5px] font-bold clar-text-faint">USERS FROM OTHER PROJECTS</label>
    <div class="flex flex-wrap gap-2">
      <% current_workspace.users.order(:name).each do |user| %>
        <label class="clar-chip cursor-pointer">
          <%= check_box_tag "user_ids[]", user.id, false, class: "sr-only peer" %>
          <span class="peer-checked:font-bold"><%= user.name %></span>
        </label>
      <% end %>
    </div>
    <label class="block text-[11.5px] font-bold clar-text-faint">WHAT THOSE PEOPLE MAY DO HERE</label>
    <%= select_tag :preset,
          options_for_select(PermissionPreset::PRESETS.keys, PermissionPreset::LEAST_PRIVILEGED),
          class: "clar-input w-full" %>
    <div class="clar-card p-3 space-y-1">
      <%# Spelled out rather than named: whoever creates the project is deciding
          what a group of people will be able to see in it. %>
      <% PermissionPreset::PRESETS.each do |label, permissions| %>
        <div class="text-[11.5px] leading-[1.45]">
          <span class="font-semibold clar-text-text"><%= label %></span>
          <span class="clar-text-faint">
            &mdash; <%= permissions.map { |permission| PermissionPreset.label(permission) }.to_sentence %>
          </span>
        </div>
      <% end %>
      <div class="text-[11.5px] clar-text-faint leading-[1.45] pt-0.5">
        Each person's switches can be tuned afterwards in Configuration &rsaquo; Users.
      </div>
    </div>

    <div class="flex justify-end gap-2">
      <button type="button" class="clar-btn" data-action="clar-modal#close">Cancel</button>
      <%= submit_tag "Create project", class: "clar-btn clar-btn-primary" %>
    </div>
  <% end %>
  </div>
</div>
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/services/project_creator_test.rb test/controllers/workshop/projects_controller_test.rb test/controllers/project_switcher_test.rb`
Expected: PASS — 6 in the creator test, 2 in the controller test, 3 in the switcher test

- [ ] **Step 7: Commit**

```bash
bin/rails tailwindcss:build
git add app/services/project_creator.rb app/controllers/workshop/projects_controller.rb \
  app/views/layouts config/routes.rb app/assets/builds test/services/project_creator_test.rb \
  test/controllers/workshop/projects_controller_test.rb
git commit -m "feat: create a project, reusing the keys and people of an existing one"
```

---

### Task 19: Who can see what, in plain words

The switches now decide six different things, and nobody outside Configuration can see
their own. Two screens have to answer out loud: the locked Configuration tab must say what
it would take to open it, and every person must be able to read their own access without
asking an administrator to check. Both read `PermissionPreset::LABELS` and `DESCRIPTIONS`
from Task 14 — the copy is shared, the markup is not, because the profile page renders in
the HR design system (`m3-*`, `layouts/application`) and Configuration renders in the
Workshop one (`clar-*`, `layouts/workshop`).

**Files:**
- Modify: `app/services/project_access.rb`, `app/controllers/profiles_controller.rb`, `app/views/profiles/show.html.erb`, `app/views/workshop/configuration/show.html.erb`
- Create: `app/views/profiles/_access_card.html.erb`
- Test: `test/controllers/profiles_access_test.rb` (new), `test/controllers/workshop/configuration_controller_test.rb`

**Interfaces:**
- Consumes: `PermissionPreset::LABELS`, `PermissionPreset::DESCRIPTIONS`, `PermissionPreset.label`, `PermissionPreset.description` (Task 14), `ProjectAccess#granted`, `#role_label`, `#workspace_admin?` (Task 3), `TAB_PERMISSIONS` (Task 8).
- Produces: `ProjectAccess#project`, `@access_rows` on the profile page.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/profiles_access_test.rb
require "test_helper"

# The profile page is the one page everyone reaches — including someone holding
# no permission at all, who is sent here by workshop_landing_path. So it is
# where "what am I allowed to see?" has to be answerable without asking an
# administrator to open Configuration and read a row of toggles aloud.
class ProfilesAccessTest < ActionDispatch::IntegrationTest
  test "a member reads their own role name and what each permission allows" do
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Project Manager"))
    sign_in_as(users(:two))

    get profile_path

    assert_response :success
    assert_match projects(:jira_project).name, response.body
    assert_match "Project Manager", response.body
    # The explanation, not only the switch name.
    assert_match PermissionPreset.description(:reporting), response.body
  end

  test "an administrator is told the privilege is workspace-wide" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))

    get profile_path

    assert_response :success
    assert_match "Administrator", response.body
    assert_match "every project in this workspace", response.body
    # Reaches a project they hold no membership row on.
    assert_match projects(:other_jira_project).name, response.body
  end

  test "someone with no project says so instead of showing an empty table" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)
    project_memberships(:two_elvium).destroy!
    sign_in_as(users(:two))

    get profile_path

    assert_response :success
    assert_match "not on any project", response.body
  end

  test "a person sees only their own projects" do
    workspace_memberships(:client_membership).update!(workspace_admin: false)
    sign_in_as(users(:client_user))

    get profile_path

    assert_response :success
    assert_match projects(:jira_project).name, response.body
    assert_no_match projects(:other_jira_project).name, response.body
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/profiles_access_test.rb`
Expected: FAIL — the profile page renders but contains no role name, so the first
assertion fails on `Project Manager` being absent.

- [ ] **Step 3: Let a ProjectAccess name its own project**

In `app/services/project_access.rb`, add below `initialize`:

```ruby
  # The screens that list access rows need to name the project each row is
  # about, and they should not have to carry it alongside.
  attr_reader :project
```

- [ ] **Step 4: Load the rows**

In `app/controllers/profiles_controller.rb`:

```ruby
  def show
    @access_rows = access_rows
  end
```

and in a `private` section at the bottom:

```ruby
  # One row per project this person can reach, each able to answer what they
  # may do there. A workspace admin reaches every project without a membership
  # row, so their list comes from the workspace rather than from memberships.
  def access_rows
    return [] unless current_workspace

    projects = if workspace_admin?
      current_workspace.projects.order(:name)
    else
      current_workspace.projects
                       .where(id: ProjectMembership.where(user_id: current_user.id).select(:project_id))
                       .order(:name)
    end

    projects.map { |project| ProjectAccess.new(current_user, project) }
  end
```

`ProfilesController` includes `WorkspaceScoped` already, and `workspace_admin?` comes from
`Authorization` via `ApplicationController` — confirm both by reading, not by assuming.

- [ ] **Step 5: Write the access card**

```erb
<%# app/views/profiles/_access_card.html.erb %>
<%# "What am I allowed to see?", answered per project. This page is in the HR
    design system, so it restates the Configuration legend in m3 markup rather
    than rendering it — the sentences come from PermissionPreset either way, so
    the two screens cannot drift apart in what they claim. %>
<div class="m3-card-elevated p-6">
  <h2 class="text-lg font-semibold mb-1" style="color: var(--color-on-surface)">Your access</h2>
  <p class="text-sm mb-4" style="color: var(--color-on-surface-variant)">
    <% if workspace_admin? %>
      You are a workspace administrator: you hold all six permissions in every project in
      this workspace, and you cannot be removed from a single one.
    <% else %>
      Permissions are set per project. To change them, ask an administrator &mdash; they
      are on each project's Configuration &rsaquo; Users.
    <% end %>
  </p>

  <% if @access_rows.empty? %>
    <p class="text-sm" style="color: var(--color-on-surface-variant)">
      You are not on any project yet.
      <% if current_membership&.time_hr_access? %>
        You do have access to Time &amp; HR, where you log your own hours and holidays.
      <% end %>
    </p>
  <% else %>
    <div class="space-y-4">
      <% @access_rows.each do |access| %>
        <div class="rounded-xl p-4" style="border: 1px solid var(--color-outline-variant)">
          <div class="flex items-baseline justify-between gap-3 mb-3">
            <span class="font-semibold" style="color: var(--color-on-surface)"><%= access.project.name %></span>
            <span class="text-xs font-semibold px-2 py-0.5 rounded-full"
                  style="background: var(--color-secondary-container); color: var(--color-on-secondary-container)">
              <%= access.role_label %>
            </span>
          </div>

          <dl class="space-y-2">
            <% PermissionPreset::PERMISSIONS.each do |permission| %>
              <% held = access.can?(permission) %>
              <div class="flex gap-3 text-sm <%= "opacity-45" unless held %>">
                <dt class="flex items-center gap-2 font-medium shrink-0" style="width: 11rem; color: var(--color-on-surface)">
                  <%# A tick or a dash, so the state survives being read without colour. %>
                  <span aria-hidden="true"><%= held ? "&#10003;".html_safe : "&ndash;".html_safe %></span>
                  <span><%= PermissionPreset.label(permission) %></span>
                  <span class="sr-only"><%= held ? "allowed" : "not allowed" %></span>
                </dt>
                <dd style="color: var(--color-on-surface-variant)"><%= PermissionPreset.description(permission) %></dd>
              </div>
            <% end %>
          </dl>
        </div>
      <% end %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Put the card on the page**

In `app/views/profiles/show.html.erb`, render `<%= render "access_card" %>` immediately
after the closing tag of the "Personal Information" card and before "Change Password" —
inside the `max-w-2xl` wrapper but **outside** the `form_with` block, because it is not
part of the form being submitted. Read the file and place it by structure, not by line
number.

- [ ] **Step 7: The locked tab says what would open it**

In `app/views/workshop/configuration/show.html.erb`, the locked branch currently says only
"Missing permission — ask an administrator". Name the permission and what it is for:

```erb
      <% needed = Workshop::ConfigurationController::TAB_PERMISSIONS[tab] %>
      <span class="clar-tab clar-tip inline-flex items-center gap-1.5 cursor-not-allowed opacity-60"
            data-tip="Needs the <%= PermissionPreset.label(needed) %> permission &mdash; <%= PermissionPreset.description(needed) %>"
            aria-label="<%= label %>: needs the <%= PermissionPreset.label(needed) %> permission"
            tabindex="0" aria-disabled="true">
```

Keep the padlock svg and the `<%= label %>` that follow it exactly as they are.

Add to `test/controllers/workshop/configuration_controller_test.rb`:

```ruby
  # A padlock with no reason beside it sends the person to ask an administrator
  # a question the screen could have answered.
  test "a locked tab names the permission it needs" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    sign_in_as(users(:one))

    get workshop_configuration_path(tab: "briefing")

    assert_response :success
    assert_match "Needs the Configuration permission", response.body
  end
```

- [ ] **Step 8: Run the tests**

Run: `bin/rails test test/controllers/profiles_access_test.rb test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS, 4 runs in the first file and the existing count plus one in the second.

- [ ] **Step 9: Build the stylesheet and commit**

```bash
bin/rails tailwindcss:build
git add app/services/project_access.rb app/controllers/profiles_controller.rb \
  app/views/profiles app/views/workshop/configuration/show.html.erb \
  app/assets/builds test/controllers/profiles_access_test.rb \
  test/controllers/workshop/configuration_controller_test.rb
git commit -m "feat: every person can read their own per-project access in plain words"
```

---

## Phase F — release two

### Task 18: Drop the old columns

**Do not start this task until release one has been in production long enough to be trusted.** It is the point of no return: once these columns are gone, the backfill cannot be re-run.

**Files:**
- Create: `db/migrate/20260913120000_drop_legacy_role_columns.rb`
- Delete: `test/migrations/backfill_per_project_permissions_test.rb`
- Modify: `app/controllers/workspaces_controller.rb`, `app/models/workspace.rb`, `test/fixtures/workspace_memberships.yml`, `test/controllers/workspaces_controller_test.rb`

**Interfaces:**
- Consumes: everything.
- Produces: a schema with no trace of the workspace-wide role.

- [ ] **Step 1: Confirm nothing reads them**

Run both greps. Either producing a hit means an earlier task left a reader behind, and that reader must be fixed before this migration runs.

```bash
grep -rn 'workshop_access\|\brole\b' app lib --include=*.rb --include=*.erb \
  | grep -v 'role_label\|role=\|aria\|role_badge\|chat_message'

grep -rn 'workspace\.\(github_token\|github_repo\|pr_review_enabled\|pr_review_prompt\|pr_poll_minutes\|pr_polled_at\|estimation_\|jira_ai_\|jira_story_points\|figma_read_enabled\|jira_status_\|github_status_\|figma_status_\)' \
  app lib --include=*.rb --include=*.erb
```

Expected: no hits on `WorkspaceMembership` from the first, and no output at all from the second.

- [ ] **Step 2: Replace the last raw reader of the role column**

`app/controllers/workspaces_controller.rb` still asks
`workspace_memberships.exists?(role: 3)` — the legacy client value, read as a
raw integer since Task 9 removed the enum. Dropping the column below makes that
line raise, so it has to go first. Its intent was "a restricted, admin-managed
account lives in one workspace and must not create or switch workspaces", which
the new model can state without naming a role:

```ruby
  # A restricted account — no HR access and no workspace privilege anywhere —
  # is managed by an administrator and belongs to one workspace, so it must not
  # create or switch workspaces. Replaces the old check on the `client` role,
  # whose column this release drops.
  def block_restricted_accounts
    memberships = current_user&.workspace_memberships
    return if memberships.blank?
    return if memberships.where(workspace_admin: true).exists?
    return if memberships.where(time_hr_access: true).exists?

    redirect_to jira_tasks_path, alert: "Your account is managed by an administrator."
  end
```

Rename the `before_action` to match. `test/controllers/workspaces_controller_test.rb`
already exists — Task 9's second fix round wrote it, precisely so this replacement would
have something to keep green. Read it first: it currently proves that
`users(:client_user)` (whose membership carries the legacy `role: 3`) is bounced and that
`users(:one)` is not. The new predicate does not look at `role` at all, so rewrite the
arrangement to express the same persona in the new terms — no HR access and no workspace
privilege — and keep both directions. The fixtures lose their `role:` line in Step 4, so an
arrangement that still sets it will not even load.

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260913120000_drop_legacy_role_columns.rb

# The workspace-wide role and its Workshop flag, replaced by six per-project
# switches and one global privilege. Also the workspace copies of the
# configuration, now that every project carries its own.
class DropLegacyRoleColumns < ActiveRecord::Migration[8.1]
  MEMBERSHIP_COLUMNS = %i[role workshop_access].freeze

  WORKSPACE_COLUMNS = %i[
    github_repo github_token figma_read_enabled
    pr_review_enabled pr_review_prompt pr_poll_minutes pr_polled_at
    estimation_trigger estimation_status_trigger estimation_field_names
    jira_ai_actions_field_id jira_ai_estimation_field_id jira_story_points_field_id
    jira_status_ok jira_status_error jira_status_checked_at
    github_status_ok github_status_error github_status_checked_at
    figma_status_ok figma_status_error figma_status_checked_at
  ].freeze

  def up
    MEMBERSHIP_COLUMNS.each do |column|
      remove_column :workspace_memberships, column if column_exists?(:workspace_memberships, column)
    end
    WORKSPACE_COLUMNS.each do |column|
      remove_column :workspaces, column if column_exists?(:workspaces, column)
    end
  end

  # Nothing in MEMBERSHIP_COLUMNS or WORKSPACE_COLUMNS may still be read when
  # this runs — Step 1's greps are how you know, and they are not optional.

  # Deliberately irreversible: restoring the columns would restore empty ones,
  # which is worse than refusing, because it looks like it worked.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

- [ ] **Step 3b: Take the estimation reader off the workspace**

Task 13 gave both `Workspace` and `Project` the `EstimationSettings` concern, whose
`estimation_field_names` calls `super`. Once this migration drops the workspace's column
that `super` has no attribute to read and every `Workspace#estimation_field_names` call
raises. Remove `include EstimationSettings` from `app/models/workspace.rb`, and grep for
`Workspace::ESTIMATION` and `workspace.estimation_` to confirm nothing reaches for it any
more — Step 1's second grep should already have caught any such reader, so a hit here means
Step 1 was not run honestly.

- [ ] **Step 4: Clean the fixtures**

Remove the `role:` and `workshop_access:` lines from every entry in
`test/fixtures/workspace_memberships.yml`, and delete
`test/migrations/backfill_per_project_permissions_test.rb`, which reads them. Then grep
`test/` for `role:` inside workspace-membership arrangements and for `workshop_access` —
any test still setting either will fail to load, and the fix is to express the persona as
`time_hr_access` plus `workspace_admin` plus the project switches.

- [ ] **Step 5: Run the whole suite on the server**

The local `pg` gem segfaults on a full run, so verify there:

```bash
ssh <production host> 'cd <app path>/current && bash -lc "RAILS_ENV=test rbenv exec bin/rails test"'
```

Expected: no failures

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260913120000_drop_legacy_role_columns.rb db/schema.rb \
  app/controllers/workspaces_controller.rb app/models/workspace.rb test
git commit -m "refactor: drop the workspace role and its copies of the project configuration"
```

---

## Deploying

Release one is Tasks 1 through 17 — including 11b and 11c — then Task 19.

**Before deploying, drain the queue.** `PrReviewJob` changed signature: it used to be
handed a workspace id and is now handed a project id. A job already enqueued when the deploy
lands would read a workspace id as a project id and review the wrong repository, or nothing.
Deploy right after a five-minute tick with nothing claimed, which this app's deploys need
anyway because the restart kills a running automation.

1. Push first — `cap deploy` reads the git remote, not the working copy.
2. `bundle exec cap production deploy`
3. Confirm the schema on the server, since MySQL leaves partial DDL behind on failure:
   `bash -lc 'cd <app path>/current && RAILS_ENV=production rbenv exec bin/rails runner "puts ProjectMembership.column_names.sort"'`
4. Turn Pricing on for the person who was a `workspace_client`, in Configuration › Users. The backfill leaves it off by design.
5. Watch the log for `IntegrationHealthJob`, which now iterates projects rather than workspaces, and confirm the topbar chips still read green.

Release two is Task 18, deployed the same way once release one is trusted.
