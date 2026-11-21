# Accept designs, then Finish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a task's design thread is accepted into the task's description (a new version with a Designs section and
small fixes, a lasting link to a frozen accepted copy), finished threads stay listed and can be reopened, and Finish
updates Jira and creates a branch holding `tasks/<KEY>/<key>.md` for the developer.

**Architecture:** every merge publishes its merge commit into a preview slot `accepted/<thread id>` that only the
next acceptance replaces; the lasting link resolves through the task's merges. A task's merge queues a hidden
`describe` turn (its own job, one tool-less Claude call) that writes the new Details version; Flosis, not the AI,
builds the Designs section. Finish writes Jira through JiraWriter and the branch through GitHub's Git Data API.

**Tech Stack:** Rails 8.1, Minitest + WebMock, Solid Queue, Stimulus, Nokogiri, ClaudeCliService, MariaDB in production.

**Spec:** `docs/superpowers/specs/2026-11-21-designs-accept-and-finish-design.md` (read it whole first); the UI
follows `docs/superpowers/specs/2026-11-21-designs-accept-and-finish-mockups.html` (mockups v2).

## Global Constraints

- Work on `production`; `git add` explicit paths; commits carry no Claude co-author or session trailer.
- Tests run as `PARALLEL_WORKERS=1 bin/rails test <files>` (the local pg gem segfaults in parallel).
- MariaDB: a JSON column is declared in its model with `attribute :<name>, :json, default: []`.
- The describe step uses the key a design turn uses: `ProjectCredentials.new(project).designs_api_key` (nil means
  the server's login).
- The design repo (`design_repo`, `design_repo_token`) and the app repo (`github_repo`, `github_token`,
  `github_branch`) never borrow each other's token.
- Nothing of Flosis's own (prompts) goes into a client's repo: the branch holds only the task file and attachments.
- Copy, exactly (`<KEY>` is `Designs::BranchNames.slug(task)`, `<n>` the version number):
  - Accept button and dialog title: `Accept designs`, `Accept designs?`; THEN lines: `Main designs will be updated` ·
    `<KEY>'s description gets v<n>: the designs' link, the merge commit, the changed screens, and small fixes where
    the designs settled something new` · `You will be moved back to <KEY>`.
  - Dialog warning: `<KEY>'s description changed since the designs were last updated (<from> → <to>). Update the
    designs first to see it in the screens.`
  - Toasts: `Accepting · the on-screen check finishes first` · `Accepting · components first, then the description`
    · `Accepting · writing <KEY>'s description`.
  - Turn label while running: `Writing <KEY>'s description`. Note after it: `<KEY>'s description is now v<n> ·
    designs linked`. Reopen note: `Reopened by <name> · branch from master <short sha>`.
  - Finished thread composer: `Accepted into master as <sha>. Reopen to change the designs again. Until you accept
    again, the link and <KEY> show this version.` / without a task: `Merged into master as <sha>. Reopen to change
    it again.`
  - Modal: `Designs accepted` · `Description updated · v<n>` · `Added Designs: the link, the merge commit and the <N>
    changed screens.` · `Changed to match the designs:` (+ bullets) | `Nothing else needed changing.` | `The text
    wasn't checked against the designs this time.` · `Designs linked` · `· the accepted version, in a new tab` ·
    `What's left` · `A branch with the task for the developer to take over, and the Jira ticket updated with the
    new description.` (no ticket: `… and a Jira ticket created with the new description.`; no GitHub: only the Jira
    half, `The Jira ticket updated with the new description.` / `A Jira ticket created with the new description.`)
    · buttons `Later`, Finish label.
  - Finish labels: `Finish · Update Jira & Create branch` · `Finish · Create Jira ticket & branch` ·
    `Finish · Update Jira & branch` (branch already created) · `Finish · Update Jira` · `Finish · Create Jira
    ticket` · `Finish · go to Ready` (no Jira, no GitHub).
  - GitHub refusal: `The project's GitHub token can't write to <repo> (<status>). It needs Contents: write —
    Configuration › GitHub.`

## Review Focus

1. **HTML descriptions.** The rich-text editor saves HTML. At every boundary (the describe input and fallback, Jira,
   the task file) links keep their addresses and the Designs section is found or put back. Pinned in Tasks 2, 5, 7
   and 8.
2. **A task without a Jira key** (`task-<id>`): its link, its folder and its file name. A ticket created at Finish
   leaves the `task-<id>` links working. Pinned in Tasks 3 and 7.
3. **A merge handed off** to a running check, or to a components turn: the describe turn is still queued after the
   eventual merge (the TurnJob `merge_after` path ends in `merge!`). Pinned in Task 4.
4. **GitHub failing midway** (a blob made, the ref refused): no success is recorded, a retry works, and an existing
   branch is never forced. Pinned in Task 7.
5. **The thread going away:** a reopened thread deleted, or the task removed from Create Tasks. The lasting link
   still opens the accepted copy. Pinned in Task 3.

---

### Task 1: Data and models

**Files:**
- Create: `db/migrate/20261121200000_add_acceptance_to_design_merges.rb`, `db/migrate/20261121200100_add_code_branch_to_tasks.rb`
- Modify: `app/models/design_merge.rb`, `app/models/design_turn.rb`, `app/models/task.rb`, `app/models/concerns/versionable_document.rb`, `db/schema.rb` (by migrating)
- Test: `test/models/design_turn_test.rb`, `test/models/task_test.rb`, `test/models/task_draft_test.rb` (create if missing)

**Interfaces:**
- Produces:
  - `design_merges`: `slot` string, `description_version` integer, `description_changes` text, `described_fallback`
    boolean (default false, null false) and `announced_at` datetime.
  - `DesignMerge` declares `attribute :description_changes, :json, default: []`.
  - `tasks`: `code_branch` string, `code_branch_sha` string, `code_branch_pushed_at` datetime and `code_branch_error`
    text.
  - `Task has_many :design_merges, dependent: :nullify`.
  - `DesignTurn` gains the kind `"describe"`, `#describe?`, `DESCRIBE_TIMEOUT_SECONDS = 240`,
    `DESCRIBE_BUDGET_USD = 2`, `DESCRIBE_EFFORT = "medium"` and `.describe_stale_after` (240 s + 5 min).
    `fail_stale!` and `#stale?` give it its own bound, like a plan's.
  - `VersionableDocument`: the origin `"designs"`, labelled `"Designs accepted"`.
  - `Task#suggested_branch` no longer repeats the key when the name starts with it.

- [ ] **Step 1: Write the failing tests**
  - `design_turn_test`: "a describe turn is stale after its own bound": a running `describe` turn started 9 min ago
    is failed by `fail_stale!` with `INTERRUPTED`, and one started 8 min ago is not.
  - `task_test`: "a suggested branch never repeats the key the name starts with": key `SCRUM-70`, name
    `SCRUM-70 Add token calculations` → `feat/scrum-70-add-token-calculations`; name `Add token calculations` →
    the same.
  - `task_draft_test`: "a version written when designs are accepted is labelled so": origin `designs` →
    `label == "Designs accepted"`, valid.
  - `design_merge` round-trip: `description_changes` holds `["a", "b"]`.
- [ ] **Step 2: Run them, expect failures** — `PARALLEL_WORKERS=1 bin/rails test test/models/design_turn_test.rb test/models/task_test.rb test/models/task_draft_test.rb` → FAIL (unknown kind / origin, the key repeated).
- [ ] **Step 3: Write the migrations and model changes as listed, then run `bin/rails db:migrate`.**
- [ ] **Step 4: Run the tests** → PASS, together with `test/models` → PASS.
- [ ] **Step 5: Commit** — `git add db/migrate/20261121200000_add_acceptance_to_design_merges.rb db/migrate/20261121200100_add_code_branch_to_tasks.rb db/schema.rb app/models/design_merge.rb app/models/design_turn.rb app/models/task.rb app/models/concerns/versionable_document.rb test/models/design_turn_test.rb test/models/task_test.rb test/models/task_draft_test.rb && git commit -m "feat: merges remember their acceptance, tasks their code branch, and turns can describe"`

### Task 2: HTML to Markdown, and Jira gets Markdown

**Files:**
- Create: `app/services/html_to_markdown.rb`
- Modify: `app/services/jira_writer.rb` (`self.plain_text`)
- Test: `test/services/html_to_markdown_test.rb`, `test/services/jira_writer_test.rb`

**Interfaces:**
- Produces: `HtmlToMarkdown.call(html) -> String`. It is Nokogiri-based and handles:
  - `h1`–`h6` → `#`;
  - `p` → blocks separated by a blank line, where consecutive paragraphs that start with `- ` or `- [ ]` join with
    single newlines;
  - empty paragraphs (`<p><br></p>`) dropped;
  - `b`/`strong` → `**`, `i`/`em` → `_`;
  - `ul`/`ol`/`li` → `- ` / `1. `;
  - `a` → `[text](href)` (bare text without an href);
  - `br` → newline, `code` → backticks, `pre` → fenced block, `blockquote` → `> `, `hr` → `---`;
  - entities decoded and the result stripped.
- `JiraWriter.plain_text(content)`: content whose `lstrip` starts with `<` goes through `HtmlToMarkdown`; anything
  else is unchanged from today.

- [ ] **Step 1: Write the failing tests** — in `html_to_markdown_test`:
  - "headings, bold and paragraphs become Markdown";
  - "a link keeps its address";
  - "dash paragraphs join into one list" (the SCRUM-70 shape `<p><b>Plans (Flosis admin)</b></p><p>- Admin creates
    a plan.</p><p>- Admin picks models.</p>` → `"**Plans (Flosis admin)**\n\n- Admin creates a plan.\n- Admin picks
    models."`);
  - "empty paragraphs and entities".

  In `jira_writer_test`: "an HTML version reaches Jira as Markdown with its links". The fake client's
  `update_issue_description` captures `description_text`; `commit_detail` of a draft whose content is
  `<p>See <a href="https://x.test/d">designs</a></p>` sends `See [designs](https://x.test/d)`.
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/services/html_to_markdown_test.rb test/services/jira_writer_test.rb` → FAIL (no HtmlToMarkdown; Jira gets `See designs`).
- [ ] **Step 3: Implement** `HtmlToMarkdown.call` and the `plain_text` switch.
- [ ] **Step 4: Run** the same → PASS; also `test/services/markdown_to_adf_test.rb test/controllers/workshop/versions_controller_test.rb` → PASS.
- [ ] **Step 5: Commit** — `git add app/services/html_to_markdown.rb app/services/jira_writer.rb test/services/html_to_markdown_test.rb test/services/jira_writer_test.rb && git commit -m "feat: a description written in the editor reaches Jira as Markdown, links and all"`

### Task 3: The accepted copy, its changes page, and the lasting link

**Files:**
- Create: `app/services/designs/changes_page.rb`, `app/services/designs/accepted_screens.rb`
- Modify: `app/services/designs/publisher.rb`, `app/services/designs/repo.rb`, `app/controllers/designs/preview_entries_controller.rb`, `app/services/designs/jira_links.rb`
- Test: `test/services/designs/publisher_test.rb`, `test/services/designs/changes_page_test.rb`, `test/services/designs/accepted_screens_test.rb`, `test/controllers/designs/preview_entries_controller_test.rb`, `test/services/designs/jira_links_test.rb`

**Interfaces:**
- Produces:
  - `Publisher::SLOT` accepts `accepted/<digits>`.
  - `Publisher#publish_commit!(sha, slot, base: nil, only: nil, page: nil) -> Pathname`. `publish!(branch, slot,
    base:)` resolves the head and delegates.
    - `only`: `["context/screen", …]`; when given, own changes are kept to those screens.
    - `page`: `{ title:, status: }`; when given with a base, `__flosis/changes.html` is written.
  - `Publisher#url(slot, nil)` → `"<base>/<org>/<project>/<slot>/design"`, with no page and no trailing slash.
  - `Designs::ChangesPage.render(title:, status:, own:, through:, screens:) -> String`. `own` is `[[ctx, id, kind]]`,
    `through` is `{ name => [[ctx, id]] }` and `screens` is the slot's `screens.json` hash. The page is static, with
    inline CSS and no script; its links are relative (`../designs/<ctx>/<id>.html` and `….changes.html`).
  - `Designs::Repo#first_parent(sha) -> String | nil`.
  - `Designs::AcceptedScreens.new(task)`: the newest DesignMerge of the task whose `slot` is published, read from
    that slot's `__flosis/changes.json` and `screens.json`. It gives:
    - `#merges` (the task's merges with a slot, oldest first);
    - `#own`: `[{ context:, context_name:, screen:, name:, kind: }]`;
    - `#through_names` (component names, as the canvas words them);
    - `#slot`;
    - `#any?`.
  - `PreviewEntriesController#task_slot` tries, in order: the AcceptedScreens slot, then the thread branch (today),
    then the key. With no page, it opens `__flosis/changes.html` when that file exists, else `index.html`.
  - `Designs::JiraLinks`: the overview link is `publisher.url(slug, nil)`. Once AcceptedScreens has any, the screen
    links are its own screens; otherwise as today.

- [ ] **Step 1: Write the failing tests**
  - `publisher_test` "a merge commit is published as an accepted copy, marked only where told, with a changes page":
    two changed screens between base and the sha, `only: ["admin/consumption"]` → a `.changes.html` for consumption
    only, `changes.json` own lists consumption, and `__flosis/changes.html` contains the title, the status and
    `../designs/admin/consumption.html`.
  - `publisher_test` "a lasting link with no page": `url("SCRUM-70", nil) == "http://localhost:3000/<org>/<project>/SCRUM-70/design"`.
  - `changes_page_test`: New and Updated grouped per context; names escaped; through line present only when any.
  - `preview_entries_controller_test`:
    - "a task's link opens its accepted copy once the thread is accepted": DesignMerge with `task`, `slot:
      "accepted/<id>"`, and `write("accepted/<id>/__flosis/changes.html", …)` → `/…/SP-1051/design` is granted on
      `accepted/<id>` at `__flosis/changes.html`;
    - "after the thread is unlinked from its task, the link still opens the accepted copy" (thread `task: nil`,
      merge keeps the task);
    - "a task with no key links by task-<id>".
  - `jira_links_test` "the overview link is the clean task link".
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/services/designs/publisher_test.rb test/services/designs/changes_page_test.rb test/services/designs/accepted_screens_test.rb test/controllers/designs/preview_entries_controller_test.rb test/services/designs/jira_links_test.rb` → FAIL.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** the same → PASS; also `test/controllers/designs/previews_controller_test.rb test/services/designs/preview_grant_test.rb` → PASS.
- [ ] **Step 5: Commit** — `git add app/services/designs/changes_page.rb app/services/designs/accepted_screens.rb app/services/designs/publisher.rb app/services/designs/repo.rb app/controllers/designs/preview_entries_controller.rb app/services/designs/jira_links.rb test/services/designs/publisher_test.rb test/services/designs/changes_page_test.rb test/services/designs/accepted_screens_test.rb test/controllers/designs/preview_entries_controller_test.rb test/services/designs/jira_links_test.rb && git commit -m "feat: an accepted thread's merge commit is published on its own, and the task's link opens it"`

### Task 4: Threads — publish the accepted copy, queue the describe turn, Reopen

**Files:**
- Modify: `app/services/designs/threads.rb`
- Test: `test/services/designs/threads_test.rb`, `test/jobs/designs/turn_job_test.rb`

**Interfaces:**
- Consumes: Task 3's `publish_commit!`, `first_parent` and `AcceptedScreens`; Task 1's columns.
- Produces:
  - `after_merge!(thread, merge)`: master is published as today. The accepted copy goes to `accepted/<thread id>`:
    - base: the first parent of the thread's first merge;
    - only: the union of its merges' `screens`;
    - page title: `<KEY> · <title>`, or the title without a task;
    - status: `Accepted <d Mon yyyy> · <short shas, comma-separated>`.

    `merge.update!(slot:)` follows. A failed publish is logged, as `publish` does. A thread with a task then gets
    `queue_describe(thread, merge)`. Jira links sync as today.
  - `Designs::Threads.queue_describe(thread, merge) -> DesignTurn`: a hidden request in the accepter's name
    (`merge.user`): `Write <KEY>'s description v<n> from the accepted designs.` It makes a `describe` turn and
    enqueues `Designs::DescribeJob`, never TurnJob.
  - `Designs::Threads.next_description_version(task) -> Integer` = the highest Details version + 1 (1 when none).
  - `Designs::Threads.reopen!(thread, user:)`:
    - refuses unless merged, and while turns run;
    - under `synchronize(wait: false)`: removes the branch's worktree if present, pushes `<master>:refs/heads/<branch>`
      (a fast-forward), then `point!`s the branch at master;
    - updates the thread to `status: "open"`, `base_sha: master`, and keeps `merged_sha`;
    - writes the Reopen note and publishes the branch.

    It raises `Busy` as other actions do.
  - `description_change(thread)` compares both texts with the Designs section stripped (Task 5's
    `DesignsSection.strip`). Until Task 5 lands, the stub `DesignsSection.strip(text) = text` lives in Task 5's file.
    Create it here, returning the text, if Task 4 runs first.

- [ ] **Step 1: Write the failing tests** (in `threads_test`, `with_threads_remote`)
  - "merging publishes the accepted copy, marked against master before the first acceptance": `merge.reload.slot ==
    "accepted/#{thread.id}"`, the slot's `__flosis/changes.json` own lists the thread's screen, and `changes.html`
    exists.
  - "a task's merge queues a describe turn out of sight, and a thread without a task does not": a `describe` turn,
    its request message `kind: "request"`, `assert_enqueued_with(job: Designs::DescribeJob)`, and no TurnJob for it.
  - "Reopen points the branch at master, opens the thread and keeps the accepted copy": the remote branch sha is
    master, the thread is open with `base_sha` master, the note is there, and the accepted slot is still on disk.
  - "a second acceptance marks the screens of both rounds": round 1 changes `admin/a`; reopen; round 2 changes
    `admin/b` → the accepted `changes.json` own lists both.
  - "Reopen is refused while a turn runs".

  In `turn_job_test`: "a merge handed to the check queues the describe turn when it lands" (the existing
  `finish_check` helper path → a `describe` turn exists).
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/services/designs/threads_test.rb test/jobs/designs/turn_job_test.rb` → FAIL.
- [ ] **Step 3: Implement.** `Designs::DescribeJob` may be an empty `perform` until Task 5.
- [ ] **Step 4: Run** the same → PASS.
- [ ] **Step 5: Commit** — `git add app/services/designs/threads.rb app/jobs/designs/describe_job.rb app/services/designs/designs_section.rb test/services/designs/threads_test.rb test/jobs/designs/turn_job_test.rb && git commit -m "feat: every merge keeps an accepted copy, a task's merge asks for its description, and a finished thread can be reopened"`

### Task 5: The describe step and the Designs section

**Files:**
- Create: `app/services/designs/designs_section.rb` (replacing Task 4's stub), `app/jobs/designs/describe_job.rb` (replacing the stub)
- Modify: `app/services/designs/prompt.rb`, `app/views/workshop/designs_module/_turn.html.erb`
- Test: `test/services/designs/designs_section_test.rb`, `test/services/designs/prompt_test.rb`, `test/jobs/designs/describe_job_test.rb`

**Interfaces:**
- Consumes: `AcceptedScreens` (Task 3), `queue_describe` (Task 4), `HtmlToMarkdown` (Task 2).
- Produces:
  - `Designs::DesignsSection.build(task) -> String | nil`: the section exactly as in spec §3, with grouping, the
    merge commit links `https://github.com/<design_repo>/commit/<sha>` and the lasting links; nil without
    acceptance.
  - `DesignsSection.insert(markdown, section) -> String`: replaces in place, else inserts after the intro.
  - `DesignsSection.strip(text) -> String`: Markdown, with HTML converted first and the section removed.
  - `DesignsSection.ensure(task, text) -> String`: Markdown with the section, when the task has an acceptance and
    the text lacks the clean link's address; otherwise the text unchanged.
  - `Designs::Prompt::DESCRIBE` (the rules of spec §2) and `Designs::Prompt.describe_message(task:, description:,
    conversation:, screens:, ahead:) -> String`.
  - `Designs::DescribeJob#perform(turn_id)`:
    - queue `:designs`, `limits_concurrency` sharing TurnJob's group and key;
    - claims a queued (or stale) turn;
    - test seam `self.claude_factory` (as TurnJob's);
    - calls `ClaudeCliService` with `codebase_path: ChatStreaming::NO_CODEBASE_DIR`, `allowed_tools: []`, the designs
      key, the DESCRIBE bounds and `send_initial_streaming`;
    - parses `<description>` and `<changes>` (at most 3 bullets).

    Then it saves the version: a `TaskDraft` with source `ai`, origin `designs`, version
    `next_description_version`, `make_current!`. It updates:
    - the merge: `description_version`, `description_changes`, `described_fallback`;
    - the thread's `described_*`, only when the description was not ahead;
    - the stage to `details` when it was `new` or `briefing`.

    It posts the note and `succeed!(commit_sha: nil)`. Any Claude failure falls back. Only a failure to save fails
    the turn (`fail!` and an error message in the chat).
  - `_turn.html.erb`: a running describe turn reads `Writing <KEY>'s description`.

- [ ] **Step 1: Write the failing tests**
  - `designs_section_test`:
    - "the section lists the merge commit, new and updated screens per context, and the through line";
    - "screens sharing a name before the dash are grouped" (`Profile Settings` + 3 states → `Profile Settings (+3
      states)`, and `Consumption — this month` + `— all time` → `Consumption — [this month](…), [all time](…)`);
    - "two acceptances list both merge commits";
    - "insert puts it under the intro and replaces it in place later";
    - "strip removes it from Markdown and from the editor's HTML";
    - "ensure puts it back only when the link is missing".
  - `prompt_test` "the describe message keeps the structure rule and says when the description is newer".
  - `describe_job_test`, with a stub factory streaming a `result` line:
    - "the accepted designs become the next Details version, with the section under the intro": v5, origin
      `designs`, current, the section present, merge fields set, the note posted, the turn succeeded;
    - "when Claude fails, the version still comes with the section only, and says so": `described_fallback` true;
    - "a description that is ahead of the designs keeps the thread's record of what they saw";
    - "a task in Briefing gets Details v1 from its brief and moves to Details";
    - "an HTML current version falls back to Markdown with its links".
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/services/designs/designs_section_test.rb test/services/designs/prompt_test.rb test/jobs/designs/describe_job_test.rb` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same, plus `test/services/designs/threads_test.rb test/services/designs/leak_guard_test.rb` → PASS.
- [ ] **Step 5: Commit** — `git add app/services/designs/designs_section.rb app/jobs/designs/describe_job.rb app/services/designs/prompt.rb app/views/workshop/designs_module/_turn.html.erb test/services/designs/designs_section_test.rb test/services/designs/prompt_test.rb test/jobs/designs/describe_job_test.rb && git commit -m "feat: accepted designs write the task's next description version, with the Designs section"`

### Task 6: Designs UI — Accept designs, the way back, Finished, Reopen

**Files:**
- Create: `app/javascript/controllers/designs_go_controller.js`
- Modify: `config/routes.rb` (design_threads `post :reopen`), `app/controllers/workshop/design_threads_controller.rb`, `app/controllers/workshop/designs_module_controller.rb`, `app/views/workshop/designs_module/_canvas.html.erb`, `_merge_modal.html.erb`, `_list_panel.html.erb`, `_thread_panel.html.erb`, `_messages.html.erb`, `show.html.erb`
- Test: `test/controllers/workshop/designs_module_controller_test.rb`, `test/controllers/workshop/design_threads_controller_test.rb`

**Interfaces:**
- Consumes: `reopen!`, `AcceptedScreens`, `Publisher#url(slug, nil)`.
- Produces:
  - **The canvas.** A task's open thread shows **Accept designs** (check icon) and the accept dialog (mockup step 1,
    Global copy), with the warning when `description_change` is present. The dialog's v<n> is
    `Designs::Threads.next_description_version(thread.task)`. A thread without a task keeps Merge to master and
    today's dialog.
  - **`DesignThreadsController#merge`.** On a task's thread it redirects to the thread, with the Accepting toast
    that fits (a check, components first, or merged at once). A task-less thread behaves as today.
  - **`DesignThreadsController#reopen`.** It redirects to the thread with the toast `Reopened · new branch from
    master`; Busy and the error messages are handled as the other actions handle them.
  - **`DesignsModuleController`.** `@finished` lists merged threads, newest `merged_at` first. A merged thread's
    canvas uses, in order: `accepted/<id>` when published, else its branch slot when published, else master. Its
    modes are `accepted` and `changes`.
  - **The list.** A FINISHED · n section sits after the open threads (mockup step 6): opacity `.55`, `.8` on hover;
    the filter covers it; Deleted stays last.
  - **The finished thread panel.** A badge, the date, **Open designs** (the clean link, `target="_blank"`, task
    threads only), **Reopen**, and the composer text.
  - **The way back.** `_messages.html.erb` renders `<div data-controller="designs-go"
    data-designs-go-url-value="<task Details path>">` when all of these hold:
    - the thread's last turn is a succeeded `describe`;
    - its merge's `announced_at` is nil;
    - its request's user is `current_user`;
    - the task is in the pipeline.

    `designs_go_controller` calls `Turbo.visit(url)` on connect.

- [ ] **Step 1: Write the failing tests**
  - `designs_module_controller_test`:
    - "a task's thread offers Accept designs, with the three steps";
    - "a thread without a task keeps Merge to master";
    - "the accept dialog warns when the description changed since the designs were last updated";
    - "finished threads list greyed under Finished, after the open ones";
    - "a finished thread shows its accepted copy with Accepted and Changes, Open designs and Reopen";
    - "once the description is written, the person who accepted is sent to the task", which checks that the
      `designs-go` element is there for that user and absent for another user and after `announced_at`.
  - `design_threads_controller_test`:
    - "Accept on a task's thread stays on the thread";
    - "Reopen opens a finished thread again".
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/controllers/workshop/designs_module_controller_test.rb test/controllers/workshop/design_threads_controller_test.rb` → FAIL.
- [ ] **Step 3: Implement**, matching the mockups' markup and classes.
- [ ] **Step 4: Run** the same → PASS.
- [ ] **Step 5: Commit** — `git add app/javascript/controllers/designs_go_controller.js config/routes.rb app/controllers/workshop/design_threads_controller.rb app/controllers/workshop/designs_module_controller.rb app/views/workshop/designs_module/_canvas.html.erb app/views/workshop/designs_module/_merge_modal.html.erb app/views/workshop/designs_module/_list_panel.html.erb app/views/workshop/designs_module/_thread_panel.html.erb app/views/workshop/designs_module/_messages.html.erb app/views/workshop/designs_module/show.html.erb test/controllers/workshop/designs_module_controller_test.rb test/controllers/workshop/design_threads_controller_test.rb && git commit -m "feat: Accept designs on a task's thread, finished threads stay listed, and Reopen"`

### Task 7: The task file and the branch on GitHub

**Files:**
- Create: `app/services/task_file.rb`, `app/services/task_branch.rb`
- Modify: `app/services/github_client.rb`
- Test: `test/services/task_file_test.rb`, `test/services/task_branch_test.rb`, `test/services/github_client_test.rb`

**Interfaces:**
- Consumes: `DesignsSection.ensure`, `AcceptedScreens`, `HtmlToMarkdown`.
- Produces:
  - `TaskFile.new(task)`:
    - `#key` and `#folder` (`tasks/<KEY>`);
    - `#markdown`: the header of spec §8, then the current Details version (else the brief), as Markdown with the
      section ensured;
    - `#files -> { path => String (binary) }`: the md plus `attachments/<safe name>` for attachments of 50 MB or
      less. Duplicate names get `-2`, `-3`, and bigger files are listed in the header as not copied.
  - `GithubClient::Error < StandardError` (with `#status`), and new methods that raise it on any non-2xx:
    - `default_branch`;
    - `branch_sha(name)` (nil on 404);
    - `commit_tree_sha(sha)`;
    - `folder_paths(path, ref:)` ([] on 404);
    - `create_blob(bytes)`;
    - `create_tree(base_tree:, entries:)`;
    - `create_commit(message:, tree:, parents:)`;
    - `create_ref(name, sha)`;
    - `update_ref(name, sha)` (PATCH, `force: false`).

    `raw` learns `:patch`.
  - `TaskBranch.new(task).push! -> { ok:, branch:, sha:, error: }`:
    - branch: `task.code_branch || task.suggested_branch`; base: `project.github_branch.presence ||
      default_branch`;
    - a new branch starts from the base head; an existing one gets a commit on top;
    - files the folder no longer needs get `sha: nil` entries;
    - when the tree is unchanged, nothing is committed and it succeeds with the current sha;
    - commit message: `<KEY>: task description v<n>`.

    On success it records `code_branch`, `code_branch_sha` and `code_branch_pushed_at`, and clears the error. A
    `GithubClient::Error` records `code_branch_error` (401/403/404 get the Global refusal copy; others get GitHub's
    message) and returns `ok: false`.

- [ ] **Step 1: Write the failing tests** (WebMock)
  - `task_file_test`:
    - "the file starts with the task's links and carries the current version as Markdown";
    - "a task without a key is task-<id>";
    - "attachments go beside it; big ones are listed, not copied";
    - "an HTML version is converted, and the Designs section is put back when missing".
  - `github_client_test`: each new method's request and response, a 404 → nil or [], and a 403 → `GithubClient::Error`
    with status 403.
  - `task_branch_test`:
    - "a new branch from the default branch holds the task file and attachments";
    - "Finish again adds a commit on top and never forces";
    - "nothing changed, nothing committed";
    - "a refused token is recorded with what it needs" (403 on `create_ref` after the blobs → `ok: false`,
      `code_branch_sha` stays nil, and the error has `Contents: write`);
    - "a retry after a refusal succeeds".
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/services/task_file_test.rb test/services/task_branch_test.rb test/services/github_client_test.rb` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same, plus `test/services/github_client_for_project_test.rb` → PASS.
- [ ] **Step 5: Commit** — `git add app/services/task_file.rb app/services/task_branch.rb app/services/github_client.rb test/services/task_file_test.rb test/services/task_branch_test.rb test/services/github_client_test.rb && git commit -m "feat: a task's branch on GitHub holds its description file and attachments"`

### Task 8: Finish, the modal, the task's strip, Ready

**Files:**
- Create: `app/services/task_finish.rb`, `app/views/workshop/ideas/_designs_accepted_modal.html.erb`, `app/helpers/workshop/finish_helper.rb`
- Modify: `config/routes.rb` (ideas `post :finish; post :create_branch`), `app/controllers/workshop/ideas_controller.rb`, `app/views/workshop/ideas/show.html.erb`, `_document_panel.html.erb`, `_design_thread_strip.html.erb`, `_ready.html.erb`, `app/services/jira_writer.rb`, `app/controllers/workshop/versions_controller.rb`, `app/controllers/chat_sessions_controller.rb`
- Test: `test/controllers/workshop/ideas_controller_test.rb`, `test/controllers/workshop/design_task_strip_test.rb`, `test/services/task_finish_test.rb`, `test/services/jira_writer_test.rb`, `test/controllers/workshop/versions_controller_test.rb`

**Interfaces:**
- Consumes: `TaskBranch`, `TaskFile`, `DesignsSection.ensure`, `AcceptedScreens`.
- Produces:
  - `TaskFinish.new(task).run! -> { ok:, error:, toast: }`:
    - Jira when `jira_configured?`: `commit_detail(current_detail_draft)` (else `commit_brief` of the current brief).
      A failure returns `ok: false` and stops there.
    - Then `TaskBranch#push!` when `github_configured?`.
    - Then the task moves to `ready`. After a Jira write, `detail_saved_locally_at` is set to nil; without Jira it is
      stamped.
    - The toast names what happened: `Jira updated · branch <name> created`, `Jira ticket created · …`,
      `· the branch couldn't be created`, and so on.
  - `Workshop::FinishHelper#finish_label(task)` → the Global labels.
  - `JiraWriter.detail_text(draft) -> String` = `plain_text(DesignsSection.ensure(task, content))`. It is used by
    `commit_detail` and by `VersionsController#make_current_draft`.
  - `IdeasController`:
    - `#finish`: Ready on ok, or Details with the Jira alert;
    - `#create_branch`: Ready, with the result;
    - `#show`: `@announce` is the task's newest merge with `description_version` and no `announced_at`. It is
      stamped as it renders, and `show.html.erb` gets `data-clar-modal-open-value="designs-accepted"`.
  - The Details panel's local Finish becomes `button_to finish_label …`, posting to `finish`. Only with neither
    Jira nor GitHub does today's local finish stay.
  - **The strip.** Accepted: `✓ Accepted · <sha>`, **Open designs** (new tab), **Open in Designs**. Reopened:
    today's open strip plus an `Accepted · <sha>` link.
  - **Ready.**
    - Designs tile: `Accepted · <N> screens`, linking out in a new tab.
    - Branch card: created / failed with **Create branch** / no GitHub as `Suggested branch`, per spec §9.
  - **The Details chat prompt** gains: `If the description has a Designs section (a line starting with **Designs**
    ·), keep it exactly as it is, where it is.`

- [ ] **Step 1: Write the failing tests**
  - `task_finish_test`, with a fake JiraWriter and a WebMock'd GitHub:
    - "Jira first, then the branch, then Ready";
    - "a Jira failure stops everything";
    - "a branch failure still reaches Ready, with the reason on the task";
    - "a project with neither finishes locally as today".
  - `ideas_controller_test`:
    - "the Details panel's Finish names what it will do" (each label);
    - "Finish takes the task to Ready";
    - "the modal shows once after acceptance, then never again";
    - "the modal says what is left for a task without a ticket";
    - "Ready shows the branch that was created / the reason it was not, with Create branch".
  - `design_task_strip_test`:
    - "an accepted thread's strip opens the designs in a new tab";
    - "a reopened thread's strip links the accepted version".
  - `jira_writer_test`: "commit_detail puts the Designs section back when a later version lacks it".
  - `versions_controller_test`: "making an older Details version current sends it with the Designs section".
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/services/task_finish_test.rb test/controllers/workshop/ideas_controller_test.rb test/controllers/workshop/design_task_strip_test.rb test/services/jira_writer_test.rb test/controllers/workshop/versions_controller_test.rb` → FAIL.
- [ ] **Step 3: Implement**, matching mockups v2 (steps 3–5).
- [ ] **Step 4: Run** the same → PASS, then the full suite `PARALLEL_WORKERS=1 bin/rails test` → only the known date-dependent failures (`holiday_request`, `reports_controller`, `workshop_report`).
- [ ] **Step 5: Commit** — `git add app/services/task_finish.rb app/views/workshop/ideas/_designs_accepted_modal.html.erb app/helpers/workshop/finish_helper.rb config/routes.rb app/controllers/workshop/ideas_controller.rb app/views/workshop/ideas/show.html.erb app/views/workshop/ideas/_document_panel.html.erb app/views/workshop/ideas/_design_thread_strip.html.erb app/views/workshop/ideas/_ready.html.erb app/services/jira_writer.rb app/controllers/workshop/versions_controller.rb app/controllers/chat_sessions_controller.rb test/services/task_finish_test.rb test/controllers/workshop/ideas_controller_test.rb test/controllers/workshop/design_task_strip_test.rb test/services/jira_writer_test.rb test/controllers/workshop/versions_controller_test.rb && git commit -m "feat: Finish updates Jira and creates the task's branch, and the task says when its designs were accepted"`
