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
- Deploy in two releases. Tasks 1 through 17 are release one. Task 18 is release two and only runs after release one is confirmed in production.

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

**Modified files, grouped by what they are responsible for**

- Authorization: `app/controllers/concerns/authorization.rb`, `app/controllers/concerns/workspace_scoped.rb`, `app/models/user.rb`, `app/models/workspace_membership.rb`, `app/models/project_membership.rb`.
- Workshop gates: `app/controllers/workshop/*.rb`, `app/controllers/jira_tasks_controller.rb`, `app/controllers/jira_controller.rb`, `app/controllers/chat_sessions_controller.rb`, `app/controllers/brief_chat_sessions_controller.rb`, `app/controllers/breakdown_chat_sessions_controller.rb`, `app/controllers/brief_commits_controller.rb`, `app/controllers/task_breakdowns_controller.rb`, `app/controllers/task_drafts_controller.rb`, `app/controllers/workshop_controller.rb`.
- Credentials: `app/services/project_credentials.rb`, `app/services/project_mcp_config.rb`, `app/services/figma_client.rb`, `app/services/github_client.rb`, `app/jobs/integration_health_job.rb`, `app/jobs/pr_review_job.rb`, `app/jobs/pr_review_check_job.rb`.
- Views: `app/views/workshop/configuration/*`, `app/views/layouts/_clar_topbar.html.erb`, `app/views/layouts/_clar_sidebar.html.erb`, `app/views/workshop/reports/_metrics.html.erb`, `app/views/workshop/reports/_dev_table.html.erb`, `app/helpers/clar_helper.rb`.

**HR controllers are deliberately not in this list.** `require_admin!`, `require_employee!` and `require_product!` keep their names and gain new bodies, so `holiday_requests_controller.rb`, `timesheets_controller.rb`, `clients_controller.rb`, `projects_controller.rb`, `workspace_members_controller.rb`, `feedback_meetings_controller.rb`, `tags_controller.rb`, `timers_controller.rb`, `time_entries_controller.rb`, `holiday_balance_entries_controller.rb`, `project_memberships_controller.rb`, `workspace_settings_controller.rb`, `discord_reminder_recipients_controller.rb` and the four `reports/*` controllers are untouched.

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

- [ ] **Step 5: Commit**

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
  setup do
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

  test "Tasks opens the Jira board and its absence closes it" do
    with_permissions("Project Manager")
    get jira_tasks_path
    assert_response :success

    @membership.update!(tasks: false)
    get jira_tasks_path
    assert_redirected_to root_path
  end

  test "Configuration opens the configuration page" do
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

  test "an HR employee with no project keeps the timer's Jira task picker" do
    ProjectMembership.where(user: @user).destroy_all

    get jira_tasks_project_path(@project)

    assert_response :success
  end
end
```

The picker is a member route on `projects` (`get :jira_tasks, to: "jira#jira_tasks"`), so its helper is `jira_tasks_project_path(project)` — not a top-level path.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/permission_gates_test.rb`
Expected: FAIL — the Product Owner cases pass the page today, since Configuration is one admin-only gate

- [ ] **Step 3: Rewrite the Authorization concern**

Replace the whole body of `app/controllers/concerns/authorization.rb` with:

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

  def current_membership
    @current_membership ||= current_user&.membership_for(current_workspace)
  end

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

  def github_connection_problem?
    project = current_workshop_project
    project&.github_token.present? && project.github_status_ok == false
  end

  # Refuse the current request. A JSON caller gets a status it can read; an
  # HTML one gets the familiar redirect and flash. Redirecting a JSON fetch to
  # an HTML-only index used to raise UnknownFormat — hundreds of production
  # stack traces for requests that were merely unauthorized.
  def deny_access!(message, path, status: :forbidden)
    if request.format.json?
      render json: { error: message }, status: status
    else
      redirect_to path, alert: message
    end
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

  # Gate a controller to a product (:time_hr / :workshop).
  def require_product!(product)
    return if current_user&.can_access_product?(current_workspace, product)

    deny_access!("You don't have access to that part of the app.", product_landing_path)
  end

  def jira_record_not_found
    deny_access!("You don't have access to that.", jira_tasks_path, status: :not_found)
  end
end
```

- [ ] **Step 4: Rewrite the product predicates on User**

In `app/models/user.rb`, delete `role_in`, `admin_or_owner?`, `at_least_employee?`, `client_role?`, `workspace_client_role?`, `client_or_employee?`, `can_see_money?` and `time_hr_member?`, and replace the product block with:

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

- [ ] **Step 5: Strip the role enum and the client redirect**

In `app/models/workspace_membership.rb`, delete the `enum :role, ...` declaration and the comment block above it. Leave the column in place — Task 18 drops it.

In `app/controllers/concerns/workspace_scoped.rb`:
- delete `redirect_clients_to_jira`, its `before_action`, and the `CLIENT_ALLOWED_PREFIXES` / `CLIENT_ALLOWED_EXACT_PATHS` constants
- drop the `client_role?` branch from `product_landing_path`
- replace `workshop_projects` with `def workshop_projects = visible_jira_projects`, removing the duplicated scope

```ruby
  # Landing path for a product. The Workshop's landing is the pipeline; a
  # person holding only Tasks is redirected on from there by the ordinary gate.
  def product_landing_path(product = current_product)
    return time_entries_path unless product&.to_sym == :workshop

    workshop_pipeline_path
  end

  # The Jira projects forming the Workshop work context — the same set
  # Authorization already scopes for the Jira board.
  def workshop_projects
    visible_jira_projects
  end
```

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

- [ ] **Step 8: Commit**

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

```ruby
# app/controllers/workshop/base_controller.rb — replace the before_action block

  before_action { require_product!(:workshop) }
  before_action :require_workshop!
  # Everything under /workshop is work on tickets. The narrower permissions
  # (automations, reporting, configuration) are added by the subclasses that
  # need them, on top of this one.
  before_action { require_permission!(:tasks) }
  before_action :set_pipeline_badge
```

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

- [ ] **Step 3: Add the narrower Workshop gates**

```ruby
# app/controllers/workshop/alert_rules_controller.rb — below the existing before_actions
  before_action { require_permission!(:automations) }
```

```ruby
# app/controllers/workshop/reports_controller.rb — below the existing before_actions
  before_action { require_permission!(:reporting) }
```

- [ ] **Step 4: Run the gate test**

Run: `bin/rails test test/controllers/permission_gates_test.rb`
Expected: PASS apart from the two Configuration tab cases, which Task 8 finishes

- [ ] **Step 5: Verify no caller of a deleted predicate survives**

Run: `grep -rn 'admin_or_owner?\|client_role?\|workspace_client\|at_least_employee?\|can_see_money?\|client_or_employee?\|require_workshop_config_access!\|require_workshop_member!\|require_workspace_member!' app lib`
Expected: only hits in `app/views` and `app/helpers`, which Task 8 clears

- [ ] **Step 6: Commit**

```bash
git add app/controllers
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

  test "the last administrator cannot be removed" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)

    assert_no_difference "WorkspaceMembership.count" do
      delete workspace_member_path(@admin_membership)
    end
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

- [ ] **Step 6: Fix the index view**

In `app/views/workspace_members/index.html.erb`, replace any `membership.role` display with:

```erb
<%= membership.workspace_admin? ? "Administrator" : "Member" %>
<%= " · Time & HR" if membership.time_hr_access %>
```

- [ ] **Step 7: Run the test**

Run: `bin/rails test test/controllers/workspace_members_controller_test.rb`
Expected: PASS, 4 runs

- [ ] **Step 8: Commit**

```bash
git add app/controllers/workspace_members_controller.rb app/views/workspace_members \
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

- [ ] **Step 7: Verify nothing references a deleted predicate**

Run: `grep -rn 'admin_or_owner?\|client_role?\|workspace_client\|at_least_employee?\|can_see_money?\|workshop_role_badge\|workshop_access' app lib`
Expected: no output

- [ ] **Step 8: Run the affected tests**

Run: `bin/rails test test/helpers/clar_helper_role_badge_test.rb test/controllers/permission_gates_test.rb test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS, including the two Product Owner tab cases from Task 5

- [ ] **Step 9: Commit**

```bash
git add app/controllers/workshop/configuration_controller.rb app/views app/helpers/clar_helper.rb \
  test/helpers/clar_helper_role_badge_test.rb
git commit -m "feat: Configuration locks the tabs you lack, and views ask the new permissions"
```

---

### Task 9: Retire the legacy role tests

**Files:**
- Delete: `test/models/client_role_test.rb`, `test/controllers/client_access_test.rb`, `test/controllers/workspace_client_time_hr_test.rb`
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
git rm test/models/client_role_test.rb test/controllers/client_access_test.rb \
  test/controllers/workspace_client_time_hr_test.rb
```

- [ ] **Step 3: Add the scoping test that replaces them**

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

- [ ] **Step 4: Fix the setups in the eight remaining test files**

Each sets a role to arrange a case. Translate as follows, leaving the assertions alone:

| Old setup | New setup |
| --- | --- |
| `membership.update!(role: :admin)` | `membership.update!(workspace_admin: true)` |
| `membership.update!(role: :employee, workshop_access: true)` | `project_membership.update!(PermissionPreset.attributes_for("Project Manager"))` |
| `membership.update!(role: :client)` | `project_membership.update!(PermissionPreset.attributes_for("Project Manager").merge(automations: false, reporting: false))` |
| `membership.update!(role: :workspace_client)` | `project_membership.update!(PermissionPreset.attributes_for("Product Owner"))` |

- [ ] **Step 5: Run every test touched so far**

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

- [ ] **Step 6: Commit**

```bash
git add -A test
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

    # Existing webhooks belong to whichever project came first in their
    # workspace — there was no finer answer to give before this column.
    DiscordWebhook.reset_column_information
    DiscordWebhook.where(project_id: nil).find_each do |webhook|
      first = Project.where(workspace_id: webhook.workspace_id).order(:id).first
      webhook.update_columns(project_id: first.id) if first
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

- [ ] **Step 4: Run the test**

Run: `bin/rails db:migrate && bin/rails test test/controllers/workshop/discord_webhooks_controller_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260912124000_add_project_id_to_discord_webhooks.rb db/schema.rb app/models app/controllers
git commit -m "feat: a Discord webhook belongs to a project, not to the whole workspace"
```

---

### Task 13: Configuration edits the project

**Files:**
- Modify: `app/controllers/workshop/configuration_controller.rb`, `app/views/workshop/configuration/_integrations_tab.html.erb`, `_ai_tab.html.erb`, `_manage_github.html.erb`, `_manage_figma.html.erb`
- Test: `test/controllers/workshop/configuration_controller_test.rb` (extended)

**Interfaces:**
- Consumes: Tasks 10 through 12.
- Produces: no new interface. Every form on the page posts to the project.

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

- [ ] **Step 5: Run the test**

Run: `bin/rails test test/controllers/workshop/configuration_controller_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/controllers/workshop/configuration_controller.rb app/views/workshop/configuration \
  test/controllers/workshop/configuration_controller_test.rb
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
         title="<%= permission.to_s.humanize %>">
      <button type="button" role="switch"
              aria-checked="<%= locked || membership[permission] %>"
              aria-label="<%= permission.to_s.humanize %> for <%= membership.user.name %>"
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
        <span class="leading-[1.3] whitespace-pre-line"><%= permission.to_s.humanize.upcase.sub(" ", "\n") %></span>
      <% end %>
      <span></span>
    </div>

    <%= render partial: "workshop/configuration/user_row", collection: @members, as: :membership %>
  </div></div>

  <div class="py-3 px-5 text-[11.5px] clar-text-faint">
    Defaults by role &mdash; Project Manager: Automations, Tasks, Reporting.
    Product Owner: those plus Briefing Configuration. Administrator: everything.
    Adjust per person here.
  </div>
</div>

<%= render "invite_modal" %>
```

Change `load_users_tab` in the configuration controller to:

```ruby
  def load_users_tab
    project = current_workshop_project
    @members = project.project_memberships.includes(:user).joins(:user).order("users.name")
    # People who already have an account in this workspace but are not on this
    # project — the "Add from other project" list.
    @addable_users = User.joins(:workspace_memberships)
                         .where(workspace_memberships: { workspace_id: current_workspace.id })
                         .where.not(id: @members.map(&:user_id))
                         .order(:name)
  end
```

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
          <div>
            <div class="text-[13px] font-semibold clar-text-text"><%= permission.to_s.humanize %></div>
            <% if permission == :configuration %>
              <div class="text-[11px] clar-text-faint">Administrators only by default</div>
            <% elsif permission == :briefing_config %>
              <div class="text-[11px] clar-text-faint">Product Owners and Administrators by default</div>
            <% elsif permission == :pricing %>
              <div class="text-[11px] clar-text-faint">Rates, cost and revenue in this project</div>
            <% end %>
          </div>
          <button type="button" role="switch" aria-checked="false"
                  class="flex items-center bg-transparent border-0 p-0 cursor-pointer"
                  aria-label="<%= permission.to_s.humanize %>"
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

In `app/views/layouts/_clar_topbar.html.erb`, replace the body of the project dropdown with:

```erb
<div class="text-[10.5px] font-bold tracking-[.5px] clar-text-faint px-2.5 pt-2.5 pb-1.5">
  SWITCH PROJECT &middot; SWAPS EVERYTHING
</div>

<% workshop_projects.each do |project| %>
  <%= button_to switch_workshop_project_path, params: { project_id: project.id },
        class: "flex items-start gap-2.5 w-full py-2 px-2.5 rounded-lg text-left hover:bg-[color:var(--surface-2)]" do %>
    <span class="flex-1 min-w-0">
      <span class="block font-semibold text-[13.5px] clar-text-text truncate"><%= project.name %></span>
      <span class="block text-[11.5px] clar-text-faint truncate">
        <%= [ project.team, project.github_repo ].compact_blank.join(" · ") %>
      </span>
    </span>
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

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/controllers/project_switcher_test.rb`
Expected: the first test passes; the second passes once Task 17 supplies the modal partial. Create the partial as an empty file now so the render resolves.

- [ ] **Step 5: Commit**

```bash
bin/rails tailwindcss:build
git add app/views/layouts app/assets/builds test/controllers/project_switcher_test.rb
git commit -m "feat: the project switcher names the team and repo it is swapping to"
```

---

### Task 17: Creating a project

**Files:**
- Create: `app/services/project_creator.rb`
- Modify: `app/controllers/projects_controller.rb`, `app/views/layouts/_clar_new_project_modal.html.erb`, `config/routes.rb`
- Test: `test/services/project_creator_test.rb`

**Interfaces:**
- Consumes: `ProjectCredentials` (Task 11), `PermissionPreset`, `ProjectMembership#apply_preset`.
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
    copy_credentials_into(project)

    project.save!
    add_members(project)
    project
  end

  private

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

```ruby
# config/routes.rb — beside the existing workshop routes
  post "workshop/projects", to: "projects#create_workshop_project", as: :create_workshop_project
```

```ruby
# app/controllers/projects_controller.rb — add the action; require_admin! already guards it

  # The new-project dialog. Creates the project, switches to it, and lands on
  # its Configuration, which is where the person is going anyway.
  def create_workshop_project
    project = ProjectCreator.new(
      workspace: current_workspace,
      attributes: params.require(:project).permit(:name, :team, :github_repo).merge(external_type: "jira"),
      reuse_from: params[:reuse_from]&.permit!&.to_h,
      member_ids: params[:user_ids],
      preset: params[:preset]
    ).call

    session[:workshop_project_id] = project.id
    redirect_to workshop_configuration_path(tab: "integrations"),
                flash: { clar_toast: "#{project.name} created." }
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: workshop_pipeline_path, alert: e.record.errors.full_messages.to_sentence
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
  <%= form_with url: create_workshop_project_path, method: :post, class: "space-y-4" do |f| %>
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
    <%= hidden_field_tag :preset, "Project Manager" %>
    <p class="text-[11.5px] clar-text-faint">
      Selected people get the Project Manager defaults: Automations, Tasks, Reporting.
      Adjust them afterwards in Configuration &rsaquo; Users.
    </p>

    <div class="flex justify-end gap-2">
      <button type="button" class="clar-btn" data-action="clar-modal#close">Cancel</button>
      <%= submit_tag "Create project", class: "clar-btn clar-btn-primary" %>
    </div>
  <% end %>
  </div>
</div>
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/services/project_creator_test.rb test/controllers/project_switcher_test.rb`
Expected: PASS, 7 runs

- [ ] **Step 7: Commit**

```bash
bin/rails tailwindcss:build
git add app/services/project_creator.rb app/controllers/projects_controller.rb \
  app/views/layouts config/routes.rb app/assets/builds test/services/project_creator_test.rb
git commit -m "feat: create a project, reusing the keys and people of an existing one"
```

---

## Phase F — release two

### Task 18: Drop the old columns

**Do not start this task until release one has been in production long enough to be trusted.** It is the point of no return: once these columns are gone, the backfill cannot be re-run.

**Files:**
- Create: `db/migrate/20260913120000_drop_legacy_role_columns.rb`
- Delete: `test/migrations/backfill_per_project_permissions_test.rb`
- Modify: `test/fixtures/workspace_memberships.yml`

**Interfaces:**
- Consumes: everything.
- Produces: a schema with no trace of the workspace-wide role.

- [ ] **Step 1: Confirm nothing reads them**

Run: `grep -rn 'workshop_access\|\brole\b' app lib --include=*.rb --include=*.erb | grep -v 'role_label\|role=\|aria\|role_badge'`
Expected: no hits on `WorkspaceMembership`

- [ ] **Step 2: Write the migration**

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

  # Deliberately irreversible: restoring the columns would restore empty ones,
  # which is worse than refusing, because it looks like it worked.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

- [ ] **Step 3: Clean the fixtures**

Remove the `role:` and `workshop_access:` lines from all four entries in `test/fixtures/workspace_memberships.yml`, and delete `test/migrations/backfill_per_project_permissions_test.rb`, which reads them.

- [ ] **Step 4: Run the whole suite on the server**

The local `pg` gem segfaults on a full run, so verify there:

```bash
ssh <production host> 'cd <app path>/current && bash -lc "RAILS_ENV=test rbenv exec bin/rails test"'
```

Expected: no failures

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260913120000_drop_legacy_role_columns.rb db/schema.rb test
git commit -m "refactor: drop the workspace role and its copies of the project configuration"
```

---

## Deploying

Release one is Tasks 1 through 17.

1. Push first — `cap deploy` reads the git remote, not the working copy.
2. `bundle exec cap production deploy`
3. Confirm the schema on the server, since MySQL leaves partial DDL behind on failure:
   `bash -lc 'cd <app path>/current && RAILS_ENV=production rbenv exec bin/rails runner "puts ProjectMembership.column_names.sort"'`
4. Turn Pricing on for the person who was a `workspace_client`, in Configuration › Users. The backfill leaves it off by design.
5. Watch the log for `IntegrationHealthJob`, which now iterates projects rather than workspaces, and confirm the topbar chips still read green.

Release two is Task 18, deployed the same way once release one is trusted.
