# Workshop Designs — Plan 4: Pipeline Handoffs and Jira Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Designs joins the Workshop pipeline both ways:
- an idea can start in Designs;
- Designs hands over to Details, with Claude writing the description from the designs;
- the Briefing and Details chats work for any project, not just Elvium;
- approved designs reach the Jira issue as Web links;
- a task's branches take its Jira key once the issue exists.

**Architecture:**
- **Project-aware chats.** The existing chats look their task up among the person's Workshop projects (Jira or not), run Claude in that project's own checkout (or with no code at all), and name the project in their prompts.
- **"Continue to Details"** runs `Designs::DescribeJob`, a read-only Claude turn over the approved or working designs. Its `<draft>` becomes the current Details version.
- **Jira links** are remote links, upserted by a stable `globalId` and pruned when a screen disappears. They are written with the project's own Jira credentials after each approval and when the issue is first created.
- **Renaming for the Jira key** runs as a job on the per-task concurrency key, so it never overlaps a design turn.

**Tech Stack:** Rails 8.1, Minitest, WebMock (already used for Jira), Solid Queue.

**Spec:** `docs/superpowers/specs/2026-10-30-workshop-designs-design.md` ("Moving between Briefing, Details and Designs", "Jira links", "The pilot", prerequisite 1). **Builds on:** Plans 1–3. Check `Designs::Approval`, `Designs::WorkingBranch`, `Designs::CurrentDescription`, `Designs::TurnJob.claude_factory`, `DesignApproval` and `ChatSession` purpose `designs` before starting.

## Global Constraints

- Everything in Plan 1's Global Constraints still holds.
- **Jira writes** return `{ ok:, error: }`, keep the local state on failure, show the error, and never flip a status silently.
- **Credentials.** Jira link writes use **the project's** credentials: `JiraClient.new(domain: creds.jira_site, email: creds.jira_email, api_token: creds.jira_api_token)`.
- **The description stays untouched.** Links never go into the Jira description.
- **Link identity.** `globalId` is `"flosis-design:<project id>:<slug>:<screen path>:<ctx joined by ,>"`. The overview link uses `"flosis-design:<project id>:<slug>:index"`.
- **Link titles** are `"Design · <screen title> · <context names joined by ' + '>"`. The overview is titled `"Design · <slug> · overview"`.
- **Rename lock.** `Designs::RenameForJiraJob` and `Designs::DescribeJob` use the same `limits_concurrency` key as `Designs::TurnJob`: the task id.
- **Pilot rule.** The pilot is Gold, so no chat prompt may name Elvium unless the task's project is Elvium.

## Review Focus

1. **Jira sync runs every 15 minutes** and overwrites the description. The links must survive it, because they never touch the description.
   → Task 4 "syncing links never writes the description".
2. **A re-approval that removed a screen.** Its stale link is deleted from the issue.
   → Task 4 "a screen gone from the manifest loses its link".
3. **A project whose Jira site differs from the server's `.env`.** Its links go to the project's own site.
   → Task 4 "links are written with the project's own Jira credentials".
4. **The issue is created while a design turn is queued.** The rename must not run in the middle of a turn.
   → Task 5 "renaming shares the design turn's lock".
5. **A project without Jira.** "Continue to Details" works, and the links step says why it was skipped instead of failing.
   → Task 3 "Continue to Details works without Jira"; Task 4 "a project without Jira skips links with a reason".

---

## File Structure

**New files**

| Path | Responsibility |
| --- | --- |
| `db/migrate/20261102100000_add_designs_pipeline_columns.rb` | `tasks.designs_described_sha`, `design_approvals.jira_links_synced_at` and `jira_links_error` |
| `app/jobs/designs/describe_job.rb` | Writes the Details description from the designs |
| `app/services/designs/jira_links.rb` | Builds and syncs the Web links for a task |
| `app/jobs/designs/sync_jira_links_job.rb` | Runs `JiraLinks` for an approval and records the outcome |
| `app/jobs/designs/rename_for_jira_job.rb` | Moves `task-<id>` names to the Jira key |

**Modified files**

- Chats: `app/controllers/concerns/chat_streaming.rb`, `app/controllers/chat_sessions_controller.rb`, `app/controllers/brief_chat_sessions_controller.rb`, `app/controllers/breakdown_chat_sessions_controller.rb`.
- Starting an idea in Designs: `app/controllers/workshop/ideas_controller.rb` (the `start_stage` whitelist, `push_jira` and `sync_jira` hooks) and `app/views/workshop/pipeline/_new_idea_modal.html.erb` (plus its `clar_start_stage` controller only if its copy table needs the third label).
- The Designs screen: `app/controllers/workshop/designs_controller.rb` (`continue_to_details`, `describe`) and `app/views/workshop/designs/_top_bar.html.erb` (Continue, the changed-designs banner, link status).
- Git, publishing and Jira plumbing: `app/services/designs/repo.rb` (`#read_file`, `#delete_tag!`), `app/services/designs/publisher.rb` (`#unpublish!`), `app/services/jira_client.rb` (remote link calls, a `delete` helper).
- `app/services/designs/approval.rb` — enqueues the links job.
- `config/routes.rb`.

---

### Task 1: Briefing, Details and Breakdown chats work for any project

**Files:**
- Modify: `app/controllers/concerns/chat_streaming.rb`, `app/controllers/chat_sessions_controller.rb`, `app/controllers/brief_chat_sessions_controller.rb`, `app/controllers/breakdown_chat_sessions_controller.rb`
- Test: `test/controllers/chat_sessions_controller_test.rb`, `test/controllers/brief_chat_sessions_controller_test.rb`, `test/controllers/breakdown_chat_sessions_controller_test.rb`

**Interfaces:**
- Consumes: `workshop_projects` (`WorkspaceScoped`), `Project#ai_codebase_path`, `Project#name`, `Project#context_info`.
- Produces, in `ChatStreaming`:
  - **`set_task`** looks the task up as `Task.where(project_id: workshop_projects.select(:id)).find(params[:jira_task_id])`, replacing `visible_jira_projects`. The permission gates the controllers already have stay as they are.
  - **`chat_codebase_path -> String`** returns `@task.project.ai_codebase_path`, or else `ChatStreaming::NO_CODEBASE_DIR` (`Rails.root.join("tmp/no-codebase")`, created when needed and always empty).
  - **`chat_tools -> Array<String> | nil`:**
    - with a real checkout, it is the controller's `chat_allowed_tools`;
    - without one, it is that list (or `ClaudeCliService::ALLOWED_TOOLS`) minus `Read`, `Glob` and `Grep`.
  - **`create`** builds `ClaudeCliService.new(codebase_path: chat_codebase_path, allowed_tools: chat_tools)`. `persist_initial_session!` stores that same `codebase_path`, so a `--resume` runs where the session began.
  - **`project_label -> String`** returns `"#{@task.project.name}"`, plus `" — #{context_info.squish.first(300)}"` when `context_info` is present.
- Every "the Elvium HR app" / "the Elvium codebase" in the three prompts becomes `"the #{project_label} app"` / `"the #{project_label} codebase"`. Without a checkout, the prompt says `"You have no access to this project's code; reason from the brief and ask."` instead of the investigation step.

- [ ] **Step 1: Write the failing tests** (in `chat_sessions_controller_test.rb`; mirror the lookup and prompt tests in the other two files)

```ruby
  # Never runs the real CLI: records what the chat asked for and streams nothing.
  def with_fake_cli
    captured = {}
    fake = Object.new
    fake.define_singleton_method(:send_initial_streaming) { |**| nil }
    original = ClaudeCliService.method(:new)
    ClaudeCliService.define_singleton_method(:new) { |**kw| captured.merge!(kw); fake }
    yield captured
  ensure
    ClaudeCliService.define_singleton_method(:new, original)
  end

  test "a task of a Workshop project without Jira is found" do
    project = projects(:plain_project)
    project.update!(show_in_workshop: true, external_type: nil)
    task = project.tasks.create!(name: "Local idea")
    with_fake_cli { post jira_task_chat_session_path(task) }
    assert_not_equal 404, response.status
  end

  test "the prompt names the task's own project, not Elvium" do
    project = projects(:plain_project)
    project.update!(name: "Flosis", context_info: "Time tracking and Workshop")
    task = project.tasks.create!(name: "Archive offers")
    controller = ChatSessionsController.new
    controller.instance_variable_set(:@task, task)
    prompt = controller.send(:build_initial_prompt)
    assert_includes prompt, "Flosis"
    assert_not_includes prompt, "Elvium"
  end

  test "Claude runs in the project's own checkout" do
    task = tasks(:jira_task)
    path = checkout!(task.project)
    with_fake_cli do |captured|
      post jira_task_chat_session_path(task)
      assert_equal path, captured[:codebase_path]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run each of the three files with `bin/rails test`.
Expected: FAIL — a 404 for the non-Jira project, "Elvium" in the prompt, and the default path.

- [ ] **Step 3: Make the changes above**

Keep the prompts' structure; change only the project naming and the no-code variant.

- [ ] **Step 4: Run the tests to verify they pass**

Run each file again.
Expected: PASS, every existing chat test included.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/concerns/chat_streaming.rb app/controllers/chat_sessions_controller.rb app/controllers/brief_chat_sessions_controller.rb app/controllers/breakdown_chat_sessions_controller.rb test/controllers/chat_sessions_controller_test.rb test/controllers/brief_chat_sessions_controller_test.rb test/controllers/breakdown_chat_sessions_controller_test.rb
git commit -m "fix: the Briefing, Details and Breakdown chats work for any Workshop project, not just Elvium"
```

---

### Task 2: An idea can start in Designs

**Files:**
- Modify: `app/controllers/workshop/ideas_controller.rb`, `app/views/workshop/pipeline/_new_idea_modal.html.erb`
- Test: `test/controllers/workshop/ideas_controller_test.rb`

**Interfaces:**
- Consumes: Plan 2's `workshop_idea_designs_path`.
- Produces:
  - **The start-stage whitelist** gains `"designs"`.
  - **A designs start:**
    - `enter_pipeline!(author:, stage: "new")`;
    - seeds the v0 brief from the description exactly as the briefing start does;
    - redirects to `workshop_idea_designs_path(task)` with the toast `Idea saved · "<title>" · Designs`.
  - **The modal's third START AT card**, "Designs" ("Sketch it first — the description follows from the designs."), is rendered only when the current project's Designs is on and `design_repo_status == "ready"`. The submit label reads "Save & start designing".
  - **Refusal.** `start_stage == "designs"` on a project without ready Designs falls back to `"briefing"`, as unknown values already do.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "an idea can start in Designs" do
    @project.update!(designs_enabled: true, design_repo: "a/b", design_repo_token: "t", design_repo_status: "ready")
    post workshop_ideas_path, params: { idea: { title: "Archive offers", description: "Hide old offers", start_stage: "designs" } }
    task = @project.tasks.find_by!(name: "Archive offers")
    assert_equal "new", task.workshop_stage
    assert_redirected_to workshop_idea_designs_path(task)
    assert_equal "Hide old offers", task.current_brief.content
  end

  test "without ready Designs a designs start falls back to Briefing" do
    @project.update!(designs_enabled: false)
    post workshop_ideas_path, params: { idea: { title: "X", start_stage: "designs" } }
    assert_equal "briefing", @project.tasks.find_by!(name: "X").workshop_stage
  end

  test "the new idea dialog offers Designs only when they are ready" do
    get workshop_pipeline_path
    assert_select "[data-stage=designs]", count: 0
    @project.update!(designs_enabled: true, design_repo: "a/b", design_repo_token: "t", design_repo_status: "ready")
    get workshop_pipeline_path
    assert_select "[data-stage=designs]"
  end
```

(Reuse the test file's existing setup. If it has none for `@project`, copy the Workshop sign-in block from Plan 2's `designs_controller_test.rb`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/workshop/ideas_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Make the change**

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/workshop/ideas_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/workshop/ideas_controller.rb app/views/workshop/pipeline/_new_idea_modal.html.erb test/controllers/workshop/ideas_controller_test.rb
git commit -m "feat: an idea can start in Designs"
```

---

### Task 3: From the designs to the Details description

**Files:**
- Create: `db/migrate/20261102100000_add_designs_pipeline_columns.rb`, `app/jobs/designs/describe_job.rb`
- Modify: `app/controllers/workshop/designs_controller.rb`, `app/views/workshop/designs/_top_bar.html.erb`, `config/routes.rb`
- Test: `test/jobs/designs/describe_job_test.rb`, `test/controllers/workshop/designs_controller_test.rb`

**Interfaces:**
- Consumes: Plan 2's `Designs::TurnJob.claude_factory` (reused as the seam), `Designs::CurrentDescription`, `Designs::WorkingBranch`, `Designs::Repo`; `TaskDraft`.
- Produces:
  - **Migration:** `tasks.designs_described_sha` (string), `design_approvals.jira_links_synced_at` (datetime), `design_approvals.jira_links_error` (string). All guarded.
  - **`Designs::DescribeJob.perform_later(task_id)`:**
    - `queue_as :designs`, with the same `limits_concurrency` key as `TurnJob` (the task id).
    - It runs Claude through `Designs::TurnJob.claude_factory` with `allowed_tools: %w[Read Glob Grep]`, `restricted: true`, the project key, timeout and budget, and the `wip/<slug>` worktree as `codebase_path`.
    - Its prompt asks for exactly one `<draft>…</draft>` written for a developer:
      - **Goal**;
      - **Screens** — each manifest screen with its states per context;
      - **Acceptance criteria**;
      - **Open questions**, which lists every `missing` chat message not yet answered (all of them in this version).

      The prompt includes `Designs::CurrentDescription.for(task)` as "what was agreed so far".
    - **The draft** becomes `task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", content:)` followed by `make_current!`.
    - **Bookkeeping.** It sets `tasks.designs_described_sha` to the `wip` head and adds a `system` chat message `"Description v<version> written from the designs — open Details."`.
    - **Failure.** No draft block, or an error, adds an `error` message and changes nothing else.
  - **`DesignsController#continue_to_details`** (POST):
    - sets `workshop_stage` to `"details"` when it is `new` or `briefing`;
    - enqueues `DescribeJob`;
    - redirects to `workshop_idea_path(idea, stage: "details")` with the toast `"Writing the description from the designs…"`.
  - **`DesignsController#describe`** (POST) enqueues `DescribeJob` and redirects back with the toast `"Updating the description from the designs…"`.
  - **Top bar:**
    - a "Continue to Details" button;
    - when `designs_described_sha` is present and differs from the `wip` head, a banner "The designs changed since the description was written" with an "Update description" button.
  - **Routes:** `post :continue_to_details` and `post :describe` in the `resource :designs` block.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/jobs/designs/describe_job_test.rb
require "test_helper"

class Designs::DescribeJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  teardown { Designs::TurnJob.claude_factory = nil }

  def answer_with(text)
    Designs::TurnJob.claude_factory = ->(**) {
      Object.new.tap { |c| c.define_singleton_method(:start_session) { |**| { session_id: "s", response: text } } }
    }
  end

  test "the designs become the current Details version" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                          claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      answer_with("<draft>## Goal\nArchive offers\n## Open questions\n- Restore?</draft>")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_equal "## Goal\nArchive offers\n## Open questions\n- Restore?", task.current_detail_draft.content
      assert_equal wip, task.reload.designs_described_sha
    end
  end

  test "a reply without a draft changes nothing and says so" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.project.update!(anthropic_api_key: "sk-ant")
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: "REC-1")
      session = ChatSession.create!(task: task, workspace: task.project.workspace, user: users(:one), purpose: "designs",
                                    claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
      answer_with("I could not.")
      with_remote_url(remote) { Designs::DescribeJob.perform_now(task.id) }
      assert_nil task.current_detail_draft
      assert_equal "error", session.chat_messages.last.kind
    end
  end

  test "describing shares the design turn's lock" do
    assert_equal Designs::TurnJob.concurrency_key_for(1), Designs::DescribeJob.concurrency_key_for(1)
  end
end
```

In `test/controllers/workshop/designs_controller_test.rb` add:

```ruby
  test "Continue to Details moves the idea and starts writing the description" do
    assert_enqueued_with(job: Designs::DescribeJob, args: [ @idea.id ]) do
      post continue_to_details_workshop_idea_designs_path(@idea)
    end
    assert_equal "details", @idea.reload.workshop_stage
    assert_redirected_to workshop_idea_path(@idea, stage: "details")
  end

  test "Continue to Details works without Jira" do
    @project.update!(external_type: nil)
    post continue_to_details_workshop_idea_designs_path(@idea)
    assert_equal "details", @idea.reload.workshop_stage
  end
```

`concurrency_key_for(task_id) -> "designs-task-#{task_id}"` is a small class method that both jobs expose, so their lock key is testable. Add it to `TurnJob` in this task, and have its `limits_concurrency` key lambda call it: `->(turn_id) { concurrency_key_for(DesignTurn.find(turn_id).chat_session.task_id) }`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/jobs/designs/describe_job_test.rb && bin/rails test test/controllers/workshop/designs_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the migration, the job, the two actions, the routes and the top bar additions**

- [ ] **Step 4: Migrate and run the tests to verify they pass**

Run: `bin/rails db:migrate && bin/rails test test/jobs/designs/describe_job_test.rb && bin/rails test test/controllers/workshop/designs_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20261102100000_add_designs_pipeline_columns.rb db/schema.rb app/jobs/designs/describe_job.rb app/jobs/designs/turn_job.rb app/controllers/workshop/designs_controller.rb app/views/workshop/designs/_top_bar.html.erb config/routes.rb test/jobs/designs/describe_job_test.rb test/controllers/workshop/designs_controller_test.rb
git commit -m "feat: Continue to Details — Claude writes the description from the designs"
```

---

### Task 4: Approved designs reach Jira as Web links

**Files:**
- Create: `app/services/designs/jira_links.rb`, `app/jobs/designs/sync_jira_links_job.rb`
- Modify: `app/services/jira_client.rb`, `app/services/designs/repo.rb` (`#read_file`), `app/services/designs/approval.rb`, `app/views/workshop/designs/_top_bar.html.erb`
- Test: `test/services/designs/jira_links_test.rb`, `test/services/jira_client_test.rb`

**Interfaces:**
- Consumes: `ProjectCredentials` (Jira); `Designs::Repo`, `Designs::Publisher#url`, `Designs::WorkingBranch`-style parsing of the manifest and contexts; `DesignApproval`.
- Produces:
  - **New `JiraClient` calls:**
    - `#upsert_remote_link(issue_key:, global_id:, url:, title:) -> { ok:, error: }` — `POST /rest/api/3/issue/<key>/remotelink` with `{ globalId:, object: { url:, title: } }`. Jira upserts by `globalId`.
    - `#remote_links(issue_key) -> { ok:, global_ids: Array<String>, error: }` — `GET /rest/api/3/issue/<key>/remotelink`.
    - `#delete_remote_link(issue_key:, global_id:) -> { ok:, error: }` — `DELETE /rest/api/3/issue/<key>/remotelink?globalId=<escaped>`.
    - A private `delete(path)` helper, in the `put` pattern.
  - **`Designs::Repo#read_file(ref, path) -> String | nil`** — `git show <ref>:<path>`, nil when missing.
  - **`Designs::JiraLinks.new(task)`** and **`#sync! -> { ok:, error: }`:**
    - **Skips** with `{ ok: false, error: "This project isn't connected to Jira." }` unless `ProjectCredentials#jira_configured?`, and with `{ ok: false, error: "This task has no Jira issue yet." }` unless it has a key.
    - **Builds the link set** from `design/<slug>`'s manifest and contexts, read with `read_file`:
      - the overview link;
      - for each screen, one link per value id in its `contexts` (`ctx` = the defaults, with that value replacing its own dimension's default), or one link with the defaults when the screen lists none.
    - **Writes** every link with `upsert_remote_link`.
    - **Prunes** every existing `globalId` that starts with `"flosis-design:<project id>:<slug>:"` and is not in the set.
    - Stops at the first failure and returns it.
  - **`Designs::SyncJiraLinksJob.perform_later(approval_id)`** runs `sync!` and records `jira_links_synced_at` or `jira_links_error` on the approval.
  - **`Designs::Approval#approve!`** enqueues it after a successful approval.
  - **The top bar** shows "Jira links: up to date", or "Jira links: <error>" with a "Retry links" button, for the latest approval. Retry is POST `sync_links`, a new route in the `resource :designs` block.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/services/designs/jira_links_test.rb
require "test_helper"
require "webmock/minitest"

class Designs::JiraLinksTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  setup do
    WebMock.disable_net_connect!
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
  end

  teardown do
    WebMock.reset!
    WebMock.allow_net_connect!
    ENV.delete("DESIGNS_PREVIEW_URL")
  end

  def approved_task(repo, manifest)
    task = tasks(:jira_task)
    task.update!(project: repo.project, external_reference: "REC-1")
    repo.project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt", design_preview_token: "t0k")
    dir = repo.worktree!("wip/REC-1")
    sha = commit_files(repo, dir, {
      "designs/contexts.json" => { dimensions: [ { id: "role", name: "Role", values: [ { id: "admin", name: "Admin" }, { id: "viewer", name: "Viewer" } ] } ] }.to_json,
      "designs/tasks/REC-1.json" => manifest.to_json,
      "designs/jobs.html" => "jobs"
    })
    repo.point!("design/REC-1", to: sha)
    task
  end

  test "an overview link plus one per screen and context, with the project's own Jira" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [ { path: "designs/jobs.html", title: "Jobs", contexts: %w[admin viewer] } ] })
      stub_request(:get, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink").to_return(status: 200, body: "[]")
      posts = stub_request(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink").to_return(status: 200, body: "{}")
      result = with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert result[:ok], result[:error]
      assert_requested posts, times: 3
      assert_requested(:post, "https://acme.atlassian.net/rest/api/3/issue/REC-1/remotelink") { |req|
        JSON.parse(req.body)["object"]["url"] == "https://preview.example/t0k/REC-1/designs/jobs.html?ctx=viewer"
      }
    end
  end

  test "a screen gone from the manifest loses its link" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [] })
      stale = "flosis-design:#{repo.project.id}:REC-1:designs/old.html:admin"
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: [ { globalId: stale, id: 9 } ].to_json)
      stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      delete = stub_request(:delete, %r{/remotelink\?globalId=}).to_return(status: 204)
      with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_requested delete, times: 1
    end
  end

  test "syncing links never writes the description" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = approved_task(repo, { screens: [] })
      stub_request(:get, %r{/remotelink\z}).to_return(status: 200, body: "[]")
      stub_request(:post, %r{/remotelink\z}).to_return(status: 200, body: "{}")
      with_remote_url(remote) { Designs::JiraLinks.new(task).sync! }
      assert_not_requested :put, %r{/rest/api/3/issue/REC-1\z}
    end
  end

  test "a project without Jira skips links with a reason" do
    with_design_remote do |repo, _|
      task = tasks(:jira_task)
      task.update!(project: repo.project)
      repo.project.update!(jira_site: nil, jira_email: nil, jira_api_token: nil)
      ENV.delete("JIRA_DOMAIN")
      assert_equal "This project isn't connected to Jira.", Designs::JiraLinks.new(task).sync![:error]
    end
  end
end
```

The project-credentials case ("links are written with the project's own Jira credentials") is pinned by the host `acme.atlassian.net` in the first test, which is not the `.env` domain.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/services/designs/jira_links_test.rb`
Expected: FAIL.

- [ ] **Step 3: Add the `JiraClient` calls, `Repo#read_file`, `JiraLinks`, the job, the approval hook, the route and the top bar status**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/services/designs/jira_links_test.rb && bin/rails test test/services/designs/approval_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/jira_client.rb app/services/designs/repo.rb app/services/designs/jira_links.rb app/jobs/designs/sync_jira_links_job.rb app/services/designs/approval.rb app/views/workshop/designs/_top_bar.html.erb app/controllers/workshop/designs_controller.rb config/routes.rb test/services/designs/jira_links_test.rb
git commit -m "feat: approved designs reach the Jira issue as Web links, pruned as screens change"
```

---

### Task 5: A task's branches take its Jira key

**Files:**
- Create: `app/jobs/designs/rename_for_jira_job.rb`
- Modify: `app/services/designs/repo.rb` (`#delete_tag!`), `app/services/designs/publisher.rb` (`#unpublish!`), `app/controllers/workshop/ideas_controller.rb` (`push_jira`, `sync_jira`)
- Test: `test/jobs/designs/rename_for_jira_job_test.rb`, `test/controllers/workshop/ideas_controller_test.rb`

**Interfaces:**
- Consumes: Plan 1's `Repo#rename!`, `#tags`, `#tag!`, `#push!`; `Publisher#publish!`; `BranchNames`; Task 4's `SyncJiraLinksJob`.
- Produces:
  - **`Designs::Repo#delete_tag!(name)`** deletes the tag locally and on `origin`.
  - **`Designs::Publisher#unpublish!(slot)`** removes a slot's folder; an invalid slot raises `ArgumentError`.
  - **`Designs::RenameForJiraJob.perform_later(task_id)`:**
    - `queue_as :designs`, with the `TurnJob` concurrency key.
    - It does nothing unless the task has a Jira key and `wip/task-<id>` or `design/task-<id>` exists.
    - Inside `repo.synchronize`:
      1. `rename!` both branches;
      2. re-create every `approved/task-<id>/<n>` as `approved/<KEY>/<n>` and delete the old tags;
      3. on the working branch, Flosis `git mv`s `designs/tasks/task-<id>.json` to `designs/tasks/<KEY>.json` and commits it through the `Committer`;
      4. push;
      5. publish `design/<KEY>` to `<KEY>` and `wip/<KEY>` to `wip/<KEY>`, then `unpublish!("task-<id>")` and `unpublish!("wip/task-<id>")`.
    - It updates the `designs` `ChatSession#codebase_path` to the new worktree path, then enqueues `SyncJiraLinksJob` for the latest approval, if there is one.
  - **Hooks.** `push_jira` and `sync_jira` enqueue it after a successful write, when the task's key went from blank to present.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/jobs/designs/rename_for_jira_job_test.rb
require "test_helper"

class Designs::RenameForJiraJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  test "branches, tags, the manifest and the previews move to the Jira key" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      task = tasks(:jira_task)
      task.update!(project: repo.project, external_reference: nil)
      slug = "task-#{task.id}"
      sha = commit_files(repo, repo.worktree!("wip/#{slug}"), { "designs/tasks/#{slug}.json" => '{"screens":[]}' })
      repo.point!("design/#{slug}", to: sha)
      repo.tag!("approved/#{slug}/1", at: sha)
      repo.push!("wip/#{slug}", "design/#{slug}", "approved/#{slug}/1")
      task.update!(external_reference: "REC-7")
      with_remote_url(remote) { Designs::RenameForJiraJob.perform_now(task.id) }
      assert remote_branch_sha(remote, "wip/REC-7")
      assert remote_branch_sha(remote, "design/REC-7")
      assert_nil remote_branch_sha(remote, "wip/#{slug}")
      assert_equal [ "approved/REC-7/1" ], repo.tags("approved/*")
      assert repo.read_file("wip/REC-7", "designs/tasks/REC-7.json")
      token = repo.project.reload.design_preview_token
      assert File.exist?(File.join(@preview_root, token, "REC-7"))
      assert_not File.exist?(File.join(@preview_root, token, slug))
    end
  end

  test "renaming shares the design turn's lock" do
    assert_equal Designs::TurnJob.concurrency_key_for(1), Designs::RenameForJiraJob.concurrency_key_for(1)
  end
end
```

In `test/controllers/workshop/ideas_controller_test.rb` add a test: with `JiraWriter#commit_brief` stubbed to set `external_reference` and return `{ ok: true }`, `post sync_jira_workshop_idea_path(idea, stage: "briefing")` enqueues `Designs::RenameForJiraJob` with `[ idea.id ]`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/jobs/designs/rename_for_jira_job_test.rb && bin/rails test test/controllers/workshop/ideas_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write `delete_tag!`, `unpublish!`, the job and the two hooks**

- [ ] **Step 4: Run the tests to verify they pass**

Run the same two files.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/designs/repo.rb app/services/designs/publisher.rb app/jobs/designs/rename_for_jira_job.rb app/controllers/workshop/ideas_controller.rb test/jobs/designs/rename_for_jira_job_test.rb test/controllers/workshop/ideas_controller_test.rb
git commit -m "feat: once a task gets its Jira key, its design branches, tags and previews take it"
```

---

### Task 6: Production

- [ ] **Step 1: Deploy.** Push first, then deploy right after a 5-minute automation tick.
- [ ] **Step 2: Check on Gold.**
  1. Briefing on a Gold task names Flosis, not Elvium.
  2. Start an idea in Designs, design a screen, then use Continue to Details: a new Details version appears, ending in Open questions.
  3. On a Gold task with a Jira issue, approve. The issue's Web links section lists the overview and each screen × context, and each link opens the approved prototype.
- [ ] **Step 3: On a task without an issue,** push to Jira. Within a minute the branches read `design/<KEY>`, and the links appear.
