# Clients Feature Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a workspace-level toggle (default OFF, admin-only) that shows/hides the Clients tab; when off, the nav link is hidden and `/clients` redirects away.

**Architecture:** A `clients_enabled` boolean column on `workspaces` (default false). A new admin-only `WorkspaceSettings` page reads/writes it. The layout gates the Clients nav link on it, and `ClientsController` redirects when disabled. The client *role* and client *data* are untouched.

**Tech Stack:** Rails 8.1.2, Minitest, Turbo/Stimulus, Tailwind (tailwindcss-rails), Postgres.

---

## File Structure

- **Migration** `db/migrate/20260602000001_add_clients_enabled_to_workspaces.rb` — adds the column, backfills existing rows to false.
- **Model** `app/models/workspace.rb` — column gives `clients_enabled?` for free; no code change unless a test needs it.
- **Controller** `app/controllers/workspace_settings_controller.rb` (new) — `show`/`update`, admin-only.
- **View** `app/views/workspace_settings/show.html.erb` (new) — Features section with the Clients toggle.
- **Routes** `config/routes.rb` — `resource :workspace_settings, only: [:show, :update]`.
- **Controller** `app/controllers/clients_controller.rb` — add a guard redirecting when disabled.
- **Layout** `app/views/layouts/application.html.erb` — re-add Clients nav link gated on the flag; add "Workspace Settings" link to the user menu (admin-only).
- **Tests** `test/controllers/workspace_settings_controller_test.rb` (new), `test/controllers/clients_controller_test.rb` (new), `test/models/workspace_test.rb` (new or appended).

**Fixture facts (already in repo):**
- `workspaces(:one)` — name "Test Workspace".
- `workspace_memberships`: `one_owner` (users(:one), workspace one, role 2/owner), `two_employee` (users(:two), workspace one, role 0/employee), `client_membership` (client_user, workspace one, role 3/client).
- `sign_in_as(user)` test helper exists (`test/test_helpers/session_test_helper.rb`).
- `require_admin!` redirects non-admins to `root_path`.

---

### Task 1: Add `clients_enabled` column to workspaces

**Files:**
- Create: `db/migrate/20260602000001_add_clients_enabled_to_workspaces.rb`
- Test: `test/models/workspace_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/workspace_test.rb`:

```ruby
require "test_helper"

class WorkspaceTest < ActiveSupport::TestCase
  test "clients feature is disabled by default for a new workspace" do
    workspace = Workspace.create!(name: "Fresh Co")
    assert_not workspace.clients_enabled?, "new workspaces should default to clients disabled"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/workspace_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'clients_enabled?'` (column doesn't exist yet).

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260602000001_add_clients_enabled_to_workspaces.rb`:

```ruby
class AddClientsEnabledToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    # Default OFF: existing and new workspaces start with the Clients tab hidden.
    add_column :workspaces, :clients_enabled, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 4: Migrate dev and test databases**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: migration runs, `db/schema.rb` now shows `t.boolean "clients_enabled", default: false, null: false` on `workspaces`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/models/workspace_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260602000001_add_clients_enabled_to_workspaces.rb db/schema.rb test/models/workspace_test.rb
git commit -m "feat: add clients_enabled flag to workspaces (default off)"
```

---

### Task 2: Guard ClientsController when the feature is disabled

**Files:**
- Modify: `app/controllers/clients_controller.rb`
- Test: `test/controllers/clients_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/clients_controller_test.rb`:

```ruby
require "test_helper"

class ClientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    sign_in_as(users(:one)) # owner of workspace one
  end

  test "index redirects to root when the clients feature is disabled" do
    @workspace.update!(clients_enabled: false)
    get clients_path
    assert_redirected_to root_path
  end

  test "index renders when the clients feature is enabled" do
    @workspace.update!(clients_enabled: true)
    get clients_path
    assert_response :success
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/clients_controller_test.rb`
Expected: the "redirects when disabled" test FAILS (currently renders 200 instead of redirecting). The "enabled" test passes.

- [ ] **Step 3: Add the guard**

In `app/controllers/clients_controller.rb`, add a `before_action` and its private method. The class currently begins:

```ruby
class ClientsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :set_client, only: %i[show edit update destroy]
```

Change the top to:

```ruby
class ClientsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!
  before_action :require_clients_feature!
  before_action :set_client, only: %i[show edit update destroy]
```

And add to the `private` section (alongside `set_client`):

```ruby
  # The Clients tab is a workspace-level opt-in feature (default off). When the
  # workspace hasn't enabled it, no Clients page is reachable, even by URL.
  def require_clients_feature!
    unless current_workspace&.clients_enabled?
      redirect_to root_path, alert: "The Clients feature is turned off for this workspace."
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/controllers/clients_controller_test.rb`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/clients_controller.rb test/controllers/clients_controller_test.rb
git commit -m "feat: block /clients access when the feature is disabled"
```

---

### Task 3: WorkspaceSettings controller + route

**Files:**
- Modify: `config/routes.rb:24` (add route near `resources :clients`)
- Create: `app/controllers/workspace_settings_controller.rb`
- Test: `test/controllers/workspace_settings_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/workspace_settings_controller_test.rb`:

```ruby
require "test_helper"

class WorkspaceSettingsControllerTest < ActionDispatch::IntegrationTest
  setup { @workspace = workspaces(:one) }

  test "admin can view workspace settings" do
    sign_in_as(users(:one)) # owner
    get workspace_settings_path
    assert_response :success
  end

  test "employee cannot view workspace settings" do
    sign_in_as(users(:two)) # employee
    get workspace_settings_path
    assert_redirected_to root_path
  end

  test "admin can enable the clients feature" do
    @workspace.update!(clients_enabled: false)
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { clients_enabled: "1" } }
    assert_redirected_to workspace_settings_path
    assert @workspace.reload.clients_enabled?
  end

  test "admin can disable the clients feature" do
    @workspace.update!(clients_enabled: true)
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { clients_enabled: "0" } }
    assert_redirected_to workspace_settings_path
    assert_not @workspace.reload.clients_enabled?
  end

  test "employee cannot change the clients feature" do
    @workspace.update!(clients_enabled: false)
    sign_in_as(users(:two))
    patch workspace_settings_path, params: { workspace: { clients_enabled: "1" } }
    assert_redirected_to root_path
    assert_not @workspace.reload.clients_enabled?
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: FAIL — `NameError`/`undefined method 'workspace_settings_path'` (route + controller don't exist).

- [ ] **Step 3: Add the route**

In `config/routes.rb`, immediately after line 24 (`resources :clients`), add:

```ruby
  resource :workspace_settings, only: [ :show, :update ]
```

- [ ] **Step 4: Create the controller**

Create `app/controllers/workspace_settings_controller.rb`:

```ruby
class WorkspaceSettingsController < ApplicationController
  include WorkspaceScoped

  before_action :require_admin!

  def show
    @workspace = current_workspace
  end

  def update
    if current_workspace.update(workspace_settings_params)
      redirect_to workspace_settings_path, notice: "Workspace settings updated."
    else
      @workspace = current_workspace
      render :show, status: :unprocessable_entity
    end
  end

  private

  def workspace_settings_params
    params.require(:workspace).permit(:clients_enabled)
  end
end
```

- [ ] **Step 5: Create a minimal view so `show` renders**

Create `app/views/workspace_settings/show.html.erb` (full version comes in Task 4; this minimal one makes `show` return 200):

```erb
<div class="max-w-2xl mx-auto space-y-6">
  <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)">Workspace Settings</h1>
</div>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS (all five tests).

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/workspace_settings_controller.rb app/views/workspace_settings/show.html.erb test/controllers/workspace_settings_controller_test.rb
git commit -m "feat: workspace settings controller with clients toggle"
```

---

### Task 4: Workspace Settings view — Features toggle

**Files:**
- Modify: `app/views/workspace_settings/show.html.erb`

- [ ] **Step 1: Write the full view**

Replace the contents of `app/views/workspace_settings/show.html.erb` with:

```erb
<div class="max-w-2xl mx-auto space-y-6">
  <h1 class="text-2xl font-bold" style="color: var(--color-on-surface)">Workspace Settings</h1>

  <%= form_with model: current_workspace, url: workspace_settings_path, method: :patch, class: "space-y-6" do |f| %>
    <div class="m3-card-elevated p-6">
      <h2 class="text-lg font-semibold mb-4" style="color: var(--color-on-surface)">Features</h2>

      <label class="flex items-center justify-between gap-4 cursor-pointer">
        <span class="space-y-1">
          <span class="block text-sm font-medium" style="color: var(--color-on-surface)">Clients</span>
          <span class="block text-sm" style="color: var(--color-on-surface-variant)">
            Show the Clients tab in the sidebar. When off, the Clients pages are hidden and inaccessible.
          </span>
        </span>
        <%= f.check_box :clients_enabled, class: "m3-checkbox" %>
      </label>
    </div>

    <div class="flex justify-end">
      <%= f.submit "Save Changes", class: "m3-btn m3-btn-filled" %>
    </div>
  <% end %>
</div>
```

- [ ] **Step 2: Verify the toggle round-trips (reuse Task 3 tests)**

Run: `bin/rails test test/controllers/workspace_settings_controller_test.rb`
Expected: PASS — `f.check_box :clients_enabled` submits `"1"`/`"0"`, matching the enable/disable tests.

- [ ] **Step 3: Build CSS and sanity-check the page renders**

Run: `bin/rails tailwindcss:build`
Expected: builds without error.

- [ ] **Step 4: Commit**

```bash
git add app/views/workspace_settings/show.html.erb app/assets/builds/tailwind.css
git commit -m "feat: clients feature toggle UI on workspace settings page"
```

Note: if `bin/rails tailwindcss:build` does not write to `app/assets/builds/tailwind.css` in this project, `git add -A` the actual generated asset path it reports, or skip adding a build artifact if none changed.

---

### Task 5: Nav link gating + Workspace Settings menu entry

**Files:**
- Modify: `app/views/layouts/application.html.erb` (Clients nav link region ~line 86–94; user menu region ~line 173–176)
- Test: `test/controllers/clients_controller_test.rb` (append nav assertions)

- [ ] **Step 1: Write the failing nav tests**

Append to `test/controllers/clients_controller_test.rb` (inside the class):

```ruby
  test "sidebar shows the Clients link when the feature is enabled for an admin" do
    @workspace.update!(clients_enabled: true)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", clients_path
  end

  test "sidebar hides the Clients link when the feature is disabled" do
    @workspace.update!(clients_enabled: false)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", clients_path, count: 0
  end

  test "sidebar shows the Workspace Settings link for an admin" do
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", workspace_settings_path
  end

  test "sidebar hides the Workspace Settings link for an employee" do
    sign_in_as(users(:two))
    get root_path
    assert_select "a[href=?]", workspace_settings_path, count: 0
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/clients_controller_test.rb`
Expected: the Clients-link-enabled test, and both Workspace-Settings-link tests, FAIL (link not present yet). The "hides when disabled" test passes vacuously.

- [ ] **Step 3: Re-add the Clients nav link, gated on the flag**

In `app/views/layouts/application.html.erb`, the Projects link is followed directly by the Team link (the Clients link was previously removed). Locate the Projects `<%= link_to projects_path … do %> … <% end %>` block (around line 86–89) and insert the gated Clients link immediately after its closing `<% end %>`:

```erb
              <% if current_workspace.clients_enabled? %>
                <%= link_to clients_path, class: "m3-nav-item #{current_page?(clients_path) ? 'active' : ''}" do %>
                  <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z" /></svg>
                  <span>Clients</span>
                <% end %>
              <% end %>
```

This sits inside the existing `unless current_user.client_role?(current_workspace)` admin/manage block, so the link only renders for non-client members (admins/owners reach Clients; the controller's `require_admin!` enforces it regardless).

- [ ] **Step 4: Add the Workspace Settings link to the user menu (admin-only)**

In the same file, the user-menu dropdown currently reads:

```erb
              <div class="hidden absolute bottom-full left-0 mb-2 m3-menu z-50 w-56">
                <%= link_to "Profile", profile_path, class: "m3-menu-item" %>
                <hr class="m3-menu-divider">
                <%= button_to "Sign Out", session_path, method: :delete, class: "m3-menu-item" %>
              </div>
```

Change it to:

```erb
              <div class="hidden absolute bottom-full left-0 mb-2 m3-menu z-50 w-56">
                <%= link_to "Profile", profile_path, class: "m3-menu-item" %>
                <% if current_user.admin_or_owner?(current_workspace) %>
                  <%= link_to "Workspace Settings", workspace_settings_path, class: "m3-menu-item" %>
                <% end %>
                <hr class="m3-menu-divider">
                <%= button_to "Sign Out", session_path, method: :delete, class: "m3-menu-item" %>
              </div>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/clients_controller_test.rb`
Expected: PASS (all tests, including the four nav tests).

- [ ] **Step 6: Commit**

```bash
git add app/views/layouts/application.html.erb test/controllers/clients_controller_test.rb
git commit -m "feat: gate Clients nav link on feature flag; add Workspace Settings menu link"
```

---

### Task 6: Full regression + deploy

**Files:** none (verification only)

- [ ] **Step 1: Run the touched test files together**

Run: `bin/rails test test/models/workspace_test.rb test/controllers/clients_controller_test.rb test/controllers/workspace_settings_controller_test.rb test/controllers/client_access_test.rb`
Expected: all PASS, 0 failures/errors.

- [ ] **Step 2: Run the full controller + model suite to catch regressions**

Run: `bin/rails test test/controllers test/models`
Expected: no NEW failures beyond the project's known pre-existing failures (claude_cli `--add-dir` ×3, jira_sync `fetch_all_comments`, holiday overlap). If any test that previously passed now fails because it assumed the Clients feature was on, fix that test's setup to call `workspaces(:one).update!(clients_enabled: true)` — do NOT change the production default.

- [ ] **Step 3: Commit any fixups from Step 2 (only if needed)**

```bash
git add -A
git commit -m "test: enable clients feature in setups that assume it is on"
```

- [ ] **Step 4: Push and deploy**

```bash
git push origin production
cap production deploy
```

Expected: deploy exits 0; `puma:stop` then `puma:start` both succeed (full restart).

- [ ] **Step 5: Verify on production with Playwright**

- Log in as admin (kacper@rubyonsaas.com). Confirm the sidebar has **no** Clients link (feature defaults off after the backfill).
- Open the user menu → confirm **Workspace Settings** link is present.
- Open Workspace Settings → toggle Clients **on** → Save → confirm the Clients link now appears in the sidebar.
- Toggle it **off** again → Save → confirm the link disappears and visiting `/clients` redirects to root.

---

## Notes for the implementer

- The client **role** (Jira-tasks-only login accounts) is unrelated and must not be touched.
- `current_workspace` is available in controllers/views via `WorkspaceScoped`.
- `f.check_box` renders a hidden `"0"` + checkbox `"1"`, so an unchecked box correctly submits `clients_enabled: "0"`.
- Keep the migration default `false`; the production database backfills to false automatically via the column default.
