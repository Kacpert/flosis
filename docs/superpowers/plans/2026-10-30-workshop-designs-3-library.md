# Workshop Designs — Plan 3: Library and Style Packs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Flosis team keeps one versioned library of prompts, skills and style packs that drives every design turn. Projects pick a style pack by name and never see its text. The leak guard compares each diff against exactly the library text that turn used.

**Architecture:**
- **Staff flag.** A boolean `users.flosis_staff`, which is not a workspace role, gates a staff-only Library area. The area lives inside the Workshop shell for its layout, but its data is global: one library for all of Flosis.
- **Entries and versions.** Each entry (base prompt, skill or style pack) has append-only versions.
- **Composition.** `Designs::Library.compose(project)` assembles a turn's system prompt from the current versions: the base prompt, the active skills, and the project's style pack. It returns the text, the individual texts for the leak guard, and the version ids that the turn records.

**Tech Stack:** Rails 8.1, Minitest, the existing Workshop layout and `clar-` UI.

**Spec:** `docs/superpowers/specs/2026-10-30-workshop-designs-design.md` ("The configurator and the library"). **Builds on:** Plans 1 and 2. Check that `Designs::Prompt.system_text(project:)`, `Designs::Prompt::BASE`, `Designs::TurnJob` and the Designs configuration tab landed as written.

## Global Constraints

- Everything in Plan 1's Global Constraints still holds.
- **Who sees library text.** Library text is never shown to anyone without `flosis_staff`, not even a workspace admin. Projects see only a style pack's name and description.
- **Non-staff get a 404, not a 403,** for every library URL, so the area's existence isn't confirmed.
- **Library text never enters a design repo.** The leak guard's `forbidden_texts` for a turn is exactly the composition's `texts`.
- **Versions are append-only.** Editing an entry creates a new version, and restoring an old one creates a new version with the old body.
- **The commit → library version record** is kept in Flosis (`design_turns.library_version_ids`), never in the repo.

## Review Focus

1. **A workspace admin who isn't staff** must not reach any library URL or see library text anywhere — not even in Configuration's style-pack select, which shows names only.
   → Task 4 "a workspace admin who isn't staff gets a 404"; Task 5 "the style pack select never shows the pack's text".
2. **Saving an entry unchanged** must not create an empty duplicate version.
   → Task 2 "revise! with the same body makes no new version".
3. **A project whose chosen style pack is deactivated** must keep working: the turn runs without a pack, and Configuration shows it as missing.
   → Task 3 "an inactive chosen style pack is left out"; Task 5 "a deactivated pack shows as missing".
4. **Claude copies a passage of a skill into a page.** The turn is refused.
   → Task 3 "a turn that copies library text is refused".
5. **Deleting an entry would orphan old turns' version ids,** so entries are deactivated, never deleted.
   → Task 4 "there is no destroy route".

---

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `db/migrate/20261101100000_add_flosis_staff_to_users.rb` | `users.flosis_staff` |
| `db/migrate/20261101101000_create_library.rb` | `library_entries`, `library_entry_versions`, `design_turns.library_version_ids`, `projects.design_style_pack_key`, and the seed of `designs-base` from `Designs::Prompt::BASE` |
| `app/services/flosis_staff.rb` | `grant!` and `revoke!` by email |
| `lib/tasks/flosis_staff.rake` | `flosis:staff:grant[email]`, `flosis:staff:revoke[email]` |
| `app/models/library_entry.rb`, `app/models/library_entry_version.rb` | The library |
| `app/services/designs/library.rb` | `compose(project)` |
| `app/controllers/workshop/library_entries_controller.rb` | The staff-only area |
| `app/views/workshop/library_entries/index.html.erb`, `_form.html.erb`, `new.html.erb`, `edit.html.erb`, `show.html.erb` | The staff UI |

**Modified files**

- `app/models/user.rb`
- `app/services/designs/prompt.rb` — `system_text` composes from the library.
- `app/jobs/designs/turn_job.rb` — guard texts and version ids.
- `app/models/project.rb` — style pack validation.
- `app/controllers/workshop/configuration_controller.rb` and `app/views/workshop/configuration/_designs_tab.html.erb` — the style pack select.
- `config/routes.rb`
- `app/views/layouts/_clar_sidebar.html.erb` — the staff-only Library link.

---

### Task 1: The Flosis staff flag

**Files:**
- Create: `db/migrate/20261101100000_add_flosis_staff_to_users.rb`, `app/services/flosis_staff.rb`, `lib/tasks/flosis_staff.rake`
- Modify: `app/models/user.rb` (comment only)
- Test: `test/services/flosis_staff_test.rb`

**Interfaces:**
- Produces:
  - `users.flosis_staff` (boolean, default false, not null), so `User#flosis_staff?` comes from Active Record.
  - `FlosisStaff.grant!(email) -> User` and `FlosisStaff.revoke!(email) -> User`, which raise `ActiveRecord::RecordNotFound` for an unknown email.
  - `bin/rails "flosis:staff:grant[kacper@example.com]"` prints `"<email> is now Flosis staff"`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/flosis_staff_test.rb
require "test_helper"

class FlosisStaffTest < ActiveSupport::TestCase
  test "nobody is staff by default, a workspace admin included" do
    assert_not users(:one).flosis_staff?
  end

  test "grant and revoke by email" do
    FlosisStaff.grant!(users(:one).email_address)
    assert users(:one).reload.flosis_staff?
    FlosisStaff.revoke!(users(:one).email_address)
    assert_not users(:one).reload.flosis_staff?
  end

  test "an unknown email is an error, not a silent no-op" do
    assert_raises(ActiveRecord::RecordNotFound) { FlosisStaff.grant!("nobody@example.com") }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/flosis_staff_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the migration, the service and the rake tasks**

The migration is guarded. In `user.rb`, add a comment that staff is Flosis-the-company, not a workspace role.

- [ ] **Step 4: Migrate and run the test to verify it passes**

Run: `bin/rails db:migrate && bin/rails test test/services/flosis_staff_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261101100000_add_flosis_staff_to_users.rb db/schema.rb app/services/flosis_staff.rb lib/tasks/flosis_staff.rake app/models/user.rb test/services/flosis_staff_test.rb
git commit -m "feat: a Flosis staff flag, separate from any workspace role"
```

---

### Task 2: Library entries and their versions

**Files:**
- Create: `db/migrate/20261101101000_create_library.rb`, `app/models/library_entry.rb`, `app/models/library_entry_version.rb`
- Test: `test/models/library_entry_test.rb`

**Interfaces:**
- Produces:
  - **`library_entries`:**
    - `kind` (string, not null)
    - `key` (string, not null, unique)
    - `name` (string, not null)
    - `description` (text)
    - `active` (boolean, default true, not null)
    - timestamps
  - **`library_entry_versions`:**
    - `library_entry_id` (not null)
    - `number` (integer, not null), unique on `[library_entry_id, number]`
    - `body` (text, not null)
    - `created_by_id` (nullable, references `users`)
    - `created_at` (not null)
  - **Also in this migration:**
    - `design_turns.library_version_ids` (json, nullable; MySQL JSON columns cannot have defaults — see `DesignRequest` — so the model defaults it to `[]`);
    - `projects.design_style_pack_key` (string);
    - the seed: create `LibraryEntry(kind: "base_prompt", key: "designs-base", name: "Designs base prompt")` with version 1 = `Designs::Prompt::BASE`, unless the key exists.
  - **`LibraryEntry`:**
    - `KINDS = %w[base_prompt skill style_pack].freeze`;
    - `validates :key, format: /\A[a-z0-9-]+\z/`;
    - `scope :active`, `scope :of_kind`;
    - `#current_version -> LibraryEntryVersion | nil` (the highest number);
    - `#revise!(body:, by:) -> LibraryEntryVersion` — returns the current version unchanged when the stripped body is equal;
    - `#restore!(version, by:) -> LibraryEntryVersion`.
  - `LibraryEntryVersion` `belongs_to :library_entry`, `belongs_to :created_by, class_name: "User", optional: true`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/library_entry_test.rb
require "test_helper"

class LibraryEntryTest < ActiveSupport::TestCase
  setup { @entry = LibraryEntry.create!(kind: "skill", key: "forms", name: "Forms") }

  test "revising appends a numbered version" do
    v1 = @entry.revise!(body: "Label every input.", by: users(:one))
    v2 = @entry.revise!(body: "Label every input. Show errors inline.", by: users(:one))
    assert_equal [ 1, 2 ], [ v1.number, v2.number ]
    assert_equal v2, @entry.current_version
  end

  test "revise! with the same body makes no new version" do
    @entry.revise!(body: "Label every input.", by: users(:one))
    @entry.revise!(body: "  Label every input.\n", by: users(:one))
    assert_equal 1, @entry.library_entry_versions.count
  end

  test "restoring an old version makes it current as a new version" do
    v1 = @entry.revise!(body: "one", by: users(:one))
    @entry.revise!(body: "two", by: users(:one))
    v3 = @entry.restore!(v1, by: users(:one))
    assert_equal [ 3, "one" ], [ v3.number, @entry.current_version.body ]
  end

  test "keys are lowercase words and dashes, and unique" do
    assert_not LibraryEntry.new(kind: "skill", key: "Bad Key", name: "x").valid?
    assert_not LibraryEntry.new(kind: "skill", key: "forms", name: "dup").valid?
    assert_not LibraryEntry.new(kind: "poem", key: "p", name: "x").valid?
  end

  test "the base prompt is seeded from the built-in one" do
    base = LibraryEntry.find_by!(key: "designs-base")
    assert_equal Designs::Prompt::BASE.strip, base.current_version.body.strip
  end
end
```

If fixtures wipe the seeded row (it is data, not a fixture), add `test/fixtures/library_entries.yml` and `library_entry_versions.yml` with the `designs-base` entry and its version 1, with the body read through ERB: `<%= Designs::Prompt::BASE.to_json %>`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/library_entry_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the migration and the two models**

- [ ] **Step 4: Migrate and run the test to verify it passes**

Run: `bin/rails db:migrate && bin/rails test test/models/library_entry_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261101101000_create_library.rb db/schema.rb app/models/library_entry.rb app/models/library_entry_version.rb test/models/library_entry_test.rb test/fixtures/library_entries.yml test/fixtures/library_entry_versions.yml
git commit -m "feat: a versioned library of prompts, skills and style packs"
```

---

### Task 3: Turns compose their prompt from the library

**Files:**
- Create: `app/services/designs/library.rb`
- Modify: `app/services/designs/prompt.rb`, `app/jobs/designs/turn_job.rb`, `app/models/design_turn.rb`
- Test: `test/services/designs/library_test.rb`, `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Consumes: Task 2; Plan 2's `Designs::Prompt.system_text`, `Designs::TurnJob`, `DesignTurn`.
- Produces:
  - **`Designs::Library.compose(project) -> Designs::Library::Composition`**, where `Composition = Data.define(:text, :texts, :version_ids)`. `text` joins, under these headings:
    1. `# Base` — the current `designs-base` version;
    2. `# Skill: <name>` — one per active skill, by key;
    3. `# Style pack: <name>` — when the project's `design_style_pack_key` names an active `style_pack`.

    `texts` holds each piece's body, and `version_ids` their ids in the same order.
  - **`Designs::Prompt.system_text(project:)`** returns `compose(project).text` plus the project section from Plan 2. `Designs::Prompt::BASE` stays only as the seed.
  - **`Designs::TurnJob`** passes `forbidden_texts: composition.texts` to the guard and stores `turn.update!(library_version_ids: composition.version_ids)` before running Claude.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/designs/library_test.rb
require "test_helper"

class Designs::LibraryTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @forms = LibraryEntry.create!(kind: "skill", key: "forms", name: "Forms").tap { _1.revise!(body: "Label inputs.", by: nil) }
    @old = LibraryEntry.create!(kind: "skill", key: "old", name: "Old", active: false).tap { _1.revise!(body: "Old.", by: nil) }
    @calm = LibraryEntry.create!(kind: "style_pack", key: "calm", name: "Calm").tap { _1.revise!(body: "Generous whitespace.", by: nil) }
  end

  test "base, active skills and the project's style pack, in that order" do
    @project.update!(design_style_pack_key: "calm")
    composition = Designs::Library.compose(@project)
    assert_match(/\A# Base\n.+# Skill: Forms\nLabel inputs\.\n+# Style pack: Calm\nGenerous whitespace\./m, composition.text)
    assert_not_includes composition.text, "Old."
    assert_equal 3, composition.version_ids.size
  end

  test "an inactive chosen style pack is left out" do
    @project.update!(design_style_pack_key: "calm")
    @calm.update!(active: false)
    assert_not_includes Designs::Library.compose(@project).text, "Generous whitespace."
  end
end
```

In `test/jobs/designs/turn_job_test.rb` add:

```ruby
  test "a turn records the library versions it used" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { "designs/a.html" => "a" })
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert_equal Designs::Library.compose(repo.project).version_ids, turn.reload.library_version_ids
    end
  end

  test "a turn that copies library text is refused" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      skill = "Always pair every primary action with a quiet secondary one and never stack more than two buttons."
      LibraryEntry.create!(kind: "skill", key: "buttons", name: "Buttons").revise!(body: skill, by: nil)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      fake_claude(files: { "designs/a.html" => "<p>#{skill}</p>" })
      turn = new_turn(task)
      with_remote_url(remote) { Designs::TurnJob.perform_now(turn.id) }
      assert turn.reload.failed?
      assert_match(/passage from the Flosis library/, turn.error)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/services/designs/library_test.rb && bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write `Designs::Library` and wire it into `Prompt` and `TurnJob`**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/designs/library_test.rb && bin/rails test test/jobs/designs/turn_job_test.rb`
Expected: PASS, the Plan 2 tests included.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/library.rb app/services/designs/prompt.rb app/jobs/designs/turn_job.rb app/models/design_turn.rb test/services/designs/library_test.rb test/jobs/designs/turn_job_test.rb
git commit -m "feat: design turns run on the library, and record which versions they used"
```

---

### Task 4: The staff-only Library area

**Files:**
- Create:
  - `app/controllers/workshop/library_entries_controller.rb`
  - `app/views/workshop/library_entries/index.html.erb`, `show.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- Modify: `config/routes.rb`, `app/views/layouts/_clar_sidebar.html.erb`
- Test: `test/controllers/workshop/library_entries_controller_test.rb`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - **Routes**, in `namespace :workshop`:

    ```ruby
    resources :library_entries, path: "library", except: :destroy do
      member { post :restore }
    end
    ```

  - **`Workshop::LibraryEntriesController < Workshop::BaseController`** with `before_action :require_flosis_staff!`, which raises `ActionController::RoutingError, "Not Found"` unless `current_user.flosis_staff?`.
    - **`index`** groups entries by kind under the headings "Base prompt", "Skills" and "Style packs", with name, key, active badge, version number and last editor.
    - **`create` and `update`** save name, description and active, then `revise!(body:)` with the textarea's text.
    - **`show`** lists the versions, newest first, each with "Restore" — a `button_to restore` carrying `version_id`.
    - The body textarea is monospace and tall.
  - **Sidebar:** "Library", under ADMIN, is rendered only for `current_user.flosis_staff?`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/controllers/workshop/library_entries_controller_test.rb
require "test_helper"

class Workshop::LibraryEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @entry = LibraryEntry.create!(kind: "skill", key: "forms", name: "Forms").tap { _1.revise!(body: "Label inputs.", by: nil) }
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: projects(:jira_project).id }
  end

  test "a workspace admin who isn't staff gets a 404" do
    get workshop_library_entries_path
    assert_response :not_found
    get workshop_library_entry_path(@entry)
    assert_response :not_found
  end

  test "staff see the library grouped by kind" do
    users(:one).update!(flosis_staff: true)
    get workshop_library_entries_path
    assert_response :success
    assert_select "h2", /Skills/
    assert_select "body", /Forms/
  end

  test "staff editing an entry adds a version" do
    users(:one).update!(flosis_staff: true)
    patch workshop_library_entry_path(@entry), params: { library_entry: { name: "Forms", body: "Label inputs. Inline errors." } }
    assert_equal 2, @entry.reload.current_version.number
  end

  test "staff restore an old version" do
    users(:one).update!(flosis_staff: true)
    v1 = @entry.current_version
    @entry.revise!(body: "changed", by: users(:one))
    post restore_workshop_library_entry_path(@entry), params: { version_id: v1.id }
    assert_equal "Label inputs.", @entry.reload.current_version.body
  end

  test "there is no destroy route" do
    users(:one).update!(flosis_staff: true)
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path(workshop_library_entry_path(@entry), method: :delete)
    end
  end

  test "the sidebar links the Library for staff only" do
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_library_entries_path, count: 0
    users(:one).update!(flosis_staff: true)
    get workshop_pipeline_path
    assert_select "a[href=?]", workshop_library_entries_path
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/library_entries_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the routes, the controller, the views and the sidebar link**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/workshop/library_entries_controller_test.rb`
Expected: PASS (6 runs).

- [ ] **Step 5: Commit**

```bash
git add config/routes.rb app/controllers/workshop/library_entries_controller.rb app/views/workshop/library_entries app/views/layouts/_clar_sidebar.html.erb test/controllers/workshop/library_entries_controller_test.rb
git commit -m "feat: a staff-only Library to edit and version prompts, skills and style packs"
```

---

### Task 5: A project picks its style pack

**Files:**
- Modify: `app/models/project.rb`, `app/controllers/workshop/configuration_controller.rb` (`DESIGN_FIELDS` gains `:design_style_pack_key`), `app/views/workshop/configuration/_designs_tab.html.erb`
- Test: `test/controllers/workshop/configuration_designs_tab_test.rb`

**Interfaces:**
- Consumes: Task 2; Plan 1's Designs tab.
- Produces:
  - **Validation:** `Project` validates `design_style_pack_key` as blank or the key of an active `style_pack` entry. The message is `"is not an available style pack"`.
  - **The select** "STYLE PACK" offers "None" plus each active style pack. It shows each pack's name and description, never its body.
  - **A missing pack.** If the stored key is no longer an active pack, the select shows the line `"<key> (no longer available)"` and the hint "Turns run without a style pack until you pick another."

- [ ] **Step 1: Write the failing tests**

```ruby
  test "the style pack select never shows the pack's text" do
    LibraryEntry.create!(kind: "style_pack", key: "calm", name: "Calm", description: "Quiet, roomy").revise!(body: "SECRET GUIDANCE", by: nil)
    get workshop_configuration_path(tab: "designs")
    assert_select "select[name='project[design_style_pack_key]'] option[value=calm]", /Calm/
    assert_select "body", text: /SECRET GUIDANCE/, count: 0
  end

  test "saving a style pack" do
    LibraryEntry.create!(kind: "style_pack", key: "calm", name: "Calm").revise!(body: "x", by: nil)
    patch workshop_configuration_path, params: { tab: "designs", project: { design_style_pack_key: "calm" } }
    assert_equal "calm", @project.reload.design_style_pack_key
  end

  test "a deactivated pack shows as missing" do
    pack = LibraryEntry.create!(kind: "style_pack", key: "calm", name: "Calm")
    pack.revise!(body: "x", by: nil)
    @project.update!(design_style_pack_key: "calm")
    pack.update!(active: false)
    get workshop_configuration_path(tab: "designs")
    assert_select "body", /calm \(no longer available\)/
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/configuration_designs_tab_test.rb`
Expected: FAIL.

- [ ] **Step 3: Add the validation, the permitted field and the select**

The deactivated-pack case must still render the page. Skip the validation when the value is unchanged (`will_save_change_to_design_style_pack_key?`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/workshop/configuration_designs_tab_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/project.rb app/controllers/workshop/configuration_controller.rb app/views/workshop/configuration/_designs_tab.html.erb test/controllers/workshop/configuration_designs_tab_test.rb
git commit -m "feat: a project picks a style pack by name, never seeing its text"
```

---

### Task 6: Production, and the first style pack — with Kacper

- [ ] **Step 1: Deploy** (push first, then deploy right after a 5-minute automation tick). Then grant staff on the server:
  `bin/rails "flosis:staff:grant[<Kacper's email>]"`, through the server runner reference.
- [ ] **Step 2: Draft the first style pack with Kacper.**
  - Write it in the scratchpad only, never in git: the text is the intellectual property, and it lives in the production database.
  - Its sections:
    - principles;
    - typography (scale, weights, line lengths);
    - colour use (surfaces, one accent, states);
    - spacing and radii;
    - components (buttons, forms, tables, cards, empty states — each with do / don't);
    - motion;
    - anti-patterns;
    - a review checklist Claude runs before replying.
  - Start from Kacper's standing direction:
    - calm and Apple-like;
    - `rounded-2xl`, subtle borders, generous whitespace and a clean hierarchy;
    - no icon badges in stat cards;
    - pill badges as a soft tint, not solid.
- [ ] **Step 3: Store and select it.** Kacper pastes the approved text into Library › Style packs as `calm`, then picks it for Gold in Configuration › Designs.
- [ ] **Step 4: Check end to end.** A design turn on Gold records three version ids: base, any skills, and `calm`.
