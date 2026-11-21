# Accept designs, then Finish: tying a task to its designs

Date: 2026-11-21 · Status: draft for Kacper's approval
UI source of truth: `2026-11-21-designs-accept-and-finish-mockups.html` beside this file (mockups v2, approved by
Kacper with the copy changes below; it links the app's built CSS, so run `bin/rails tailwindcss:build` first).

## Why

Kacper, 2026-11-21, before merging design thread 4 (SCRUM-70): „proces tworzenia taska i designów nie są dobrze ze
sobą połączone”. Today Merge lands a thread in master and that is all:

- the task's description never hears about the designs, though the design conversation settled things the
  description does not say (thread 4: costs in €, the month in brackets only when it differs, “(none this month)”,
  no margin on the organization's screens, Consumption as a tab in Configuration);
- the merged state cannot be opened: a merged thread disappears from the Designs list and its canvas shows today's
  master, without its changes;
- the developer who takes the task has no single place with everything: the Ready screen even shows “AI prepared a
  branch · READY … The task description is committed to the branch”, but nothing creates that branch
  (`Task#suggested_branch` is copy only).

He wants a task's designs accepted into the description, a lasting link to them, and one Finish that updates Jira
and creates a branch with the task for the developer, so that “sprawdź scrum-70.md” is all a developer's AI needs.

## Goals

1. **Accept designs** on a task's thread: the designs land in master, the task's description gets a new version with
   a Designs section and small fixes where the designs settled something new, and the person is taken back to the
   task, where a modal says what changed and what is left.
2. **A lasting link** to a task's designs, opened in a new tab (the existing sandboxed preview, not the Designs work
   window). Before the first acceptance it shows the work in progress; after it, the accepted version. After the
   thread is reopened it keeps showing the accepted version until the next acceptance; after a second acceptance it
   shows the designs at the newest merge commit and the changes of both.
3. **Finish · Update Jira & Create branch**: Jira gets the current description (the ticket is created when the task
   has none), and the app's repo gets a branch holding `tasks/<KEY>/<key>.md` and the task's attachments. The task
   moves to Ready.
4. **Finished threads stay** in Designs: at the bottom of the list, greyed, under Finished; opened, they show the
   accepted version and can be reopened.

## Non-goals

- Threads without a task keep **Merge to master** as today. They get the Finished section and the accepted copy, but
  no description, link or modal. (Finish, on the other hand, is for every task: §7.)
- No pull request, no code, no screenshots in the branch. Images pasted into the task's chats are not copied.
- No change to design, plan, check or components turns, or to how Merge decides that components come first or waits
  for a running check.
- Jira's web links to the designs (Designs::JiraLinks) stay. They now open the accepted version, because they are
  lasting links.

## Anti-goals (a failure even if it works)

- The AI rewriting the description. Its structure, order and wording stay; only what the designs changed changes
  (Kacper: „małe zmiany żeby struktura taska pozostała taka jaka jest … i dodać nowe rzeczy które się pojawiły”).
  The developer sees the design changes through the link anyway.
- The developer seeing unfinished design work: after an acceptance, the link never shows a reopened thread's work.
- Rewriting a branch a developer may already work on: Finish never force-pushes.
- Anything of Flosis's own (prompts, skills) in a client's repo: only the task file and its attachments go there.

## Constraints

- Rails 8.1, Minitest, Solid Queue; MariaDB 10.11 in production, so JSON columns are declared with `attribute :json`
  (see DesignMerge).
- The description step runs Claude on the key a design turn uses: the project's designs key
  (`ProjectCredentials#designs_api_key`), else the server's Claude login (Designs::TurnJob's rule).
- Two repos, two tokens, never mixed: the design repo (`project.design_repo`, `design_repo_token`) and the app repo
  (`project.github_repo`, `github_token`, `github_branch`). The app token may lack write access; Finish must say so
  plainly.
- The UI is in English. Copy below is Kacper's where marked.

## Approaches

The how was left to me. What was weighed for each part:

- **Who writes the new description version.** Picked: one short Claude call after the merge, with no tools, in the
  spirit of TaskHandoff, run as a turn of the thread so the chat shows it. Rejected: the thread's own design AI (it
  works in the design repo with tools, slower and riskier for a text edit); the task's Details chat (it streams in
  the browser and cannot run in the background).
- **How the merged state stays openable.** Picked: publish the merge commit into a preview slot of its own, the
  “accepted” copy, which only the next acceptance replaces. Rejected: checking out the merge commit on demand (slow
  for every open), and keeping only the branch's own copy (it misses what master already had, and a reopened thread
  overwrites it).
- **How Finish writes the branch.** Picked: GitHub's Git Data API with the project's app token, one commit holding the
  task file and attachments. Rejected: a local clone of the app repo (Designs::AppRepos clones are read-only copies
  for turns, and a clone per Finish is heavy).

## The design

### 1. Accept designs (the thread)

- On a task's thread the canvas header's **Merge to master** becomes **Accept designs** (check icon), and its dialog
  becomes **Accept designs?**: branch → master, the changed screens (as today), then a THEN box in Kacper's words:
  1. `Main designs will be updated`
  2. `<KEY>'s description gets v<n>: the designs' link, the merge commit, the changed screens, and small fixes where
     the designs settled something new` (n is the version it will get)
  3. `You will be moved back to <KEY>`

  Buttons: Cancel, **Accept designs**. The components note and “After merging, master stays read-only…” go.
- When the task's description changed since the designs were last updated (`Designs::Threads.description_change`),
  the dialog warns as it does for master: `<KEY>'s description changed since the designs were last updated (v3 →
  v4). Update the designs first to see it in the screens.` Accept stays possible.
- The click runs today's merge path unchanged (`Designs::Threads.merge_or_prepare!`: a running check merges when it
  is done, components first when due, then `merge!`). For a task's thread the person stays on the thread, which shows
  the progress (mockup step 2). Toasts: `Accepting · the on-screen check finishes first`, `Accepting · components
  first, then the description`, `Accepting · writing <KEY>'s description`.
- After every merge (`after_merge!`): the accepted copy is published (§4), and for a thread with a task a **describe
  turn** is queued (§2). A thread without a task gets the copy only.
- The thread's chat shows, in order: the components/check turns as today, today's `Merged into master as <sha> by
  <name>`, the describe turn (`Writing <KEY>'s description v<n>`), then the note `<KEY>'s description is now v<n> ·
  designs linked`.
- When the describe turn has finished and the person who accepted still has the thread open, the page goes to the
  task's Details stage, where the modal opens (§6). Only that person, and only until the modal has been shown.

### 2. The describe turn (the new version)

- A DesignTurn of kind `describe` in the thread's session, with a hidden request (`kind: "request"`), run by its own
  job, not Designs::TurnJob. Bounds: 240 s, $2, effort medium, and a `fail_stale!` bucket like a plan's. It keeps
  the thread busy (polling) while it runs, and uses no browser.
- What Claude gets:
  - the current description (`Designs::CurrentDescription.for(task)`), with Flosis's Designs section taken out;
  - the thread's conversation in order: the person's messages, description-change diffs, and the AI's summaries
    (not the check's);
  - the changed screens with their context and name, new or updated;
  - the task's key and title.
- The rules (a constant in Designs::Prompt, never in a client repo):
  - keep the structure, order and wording;
  - change only what the design conversation changed or settled (values, examples, rules, placement, copy);
  - where the designs added something the description lacks, add one short line in the section it belongs to;
  - mark an open question the conversation answered as settled;
  - same language;
  - Markdown;
  - no Designs section (Flosis adds it).

  Then up to three bullets, each at most 12 words, saying what changed in the text, for the modal. Output:
  `<description>…</description>` and `<changes>…</changes>`.
- When the description changed after the designs were last updated, the AI is told so: where the newer text
  differs from the conversation, the newer text wins.
- Flosis builds the version from the AI's text and the Designs section (§3), saves it as a Details version
  (`TaskDraft`, source `ai`, new origin `designs`, labelled **Designs accepted**) and makes it current. On the
  DesignMerge it records:
  - the version number;
  - the bullets;
  - whether it fell back.
- **Keeping track of what the designs saw.** When the designs were up to date with the description, the thread's
  `described_text`/`described_version` move to the new version, so a reopened thread does not report Flosis's own
  edit as a change. Otherwise they stay, so a reopened thread still offers Update designs for the newer edit.
  `description_change` ignores the Designs section on both sides.
- **The version number.** The new version is the next Details version: v1 when the task had none, with no v0 made.
  Its text starts from `Designs::CurrentDescription.for(task)`, so the brief for a task still in Briefing. A task in
  New or Briefing moves to Details. That Details number is the v<n> shown in the THEN box, the note, the modal and
  the task file.
- **Fallback.** When Claude fails, times out, or returns no `<description>`:
  - the version is the current text converted to Markdown, plus the Designs section;
  - the turn still succeeds;
  - the modal says `The text wasn't checked against the designs this time.`

  Only a failure to save the version fails the turn, with Try again as usual.

### 3. The Designs section (Flosis writes it, not the AI)

```
**Designs** · [Open the designs](<lasting link>) · merge commit [9f3c2a1](https://github.com/<design repo>/commit/<sha>)
- New (11): Admin › [Configuration — AI costs hidden for everyone](<lasting screen link>), … · Flosis admin › [Plans](…), …
- Updated (10): Admin › [Bug Reporting](…), … [Profile Settings](…) (+3 states)
- Through shared components: sidebar, chat panel, pipeline header, process header and 5 more
```

- **Position.** Right after the intro: the first paragraph after the first heading, else the first paragraph. On a
  later acceptance, the section in place (its first line starts with `**Designs** ·`) is replaced, so it stays where
  it is.
- **Merge commits.** After more than one acceptance: `merge commits [9f3c2a1](…), [b71d0e4](…)`, oldest first.
- **What the screens are measured against.** New and Updated count against master before the thread's first
  acceptance. The lists are the union over the thread's merges (DesignMerge#screens).
- **Names.** Context names and screen names are as the canvas shows them. A context's screens are joined with `, `
  and contexts with ` · `.
- **Grouping.** Within a context and a kind (New, Updated), screens whose names share the part before ` — ` form a
  group:
  - when the plain name is among them, `Name (+n states)`, linking to the plain screen;
  - otherwise `Name — a, b, c`, each part linking to its screen;
  - a group of one keeps its full name.
- **Empty lines.** A line with nothing on it is left out.
- **Links.** Screen links are lasting links to the screen in the task's slot
  (`/<org>/<project>/<KEY>/design/designs/<context>/<screen>.html`).
- **The section stays where the description leaves Flosis.** Later Details versions (the Details chat's drafts, an
  edit, an older version made current) may lack it. So:
  - every Jira write of a Details version (`JiraWriter#commit_detail`) and Finish's task file put the current
    section back when the outgoing text lacks it, recognized by the lasting link's address in any format;
  - the Details chat's prompt gets one rule: keep the Designs section exactly as it is.

### 4. The accepted copy, and the lasting link

- **Publishing.** Every merge publishes the merge commit into the preview slot `accepted/<thread id>` (Publisher's
  SLOT gains `accepted/<digits>`). Its changes are measured against the first parent of the thread's first merge
  commit:
  - own screens: only those in the union of the thread's merges;
  - through-component screens: computed for that range.

  Publisher learns to publish a commit (not only a branch head), to mark only the given screens, and to take a title.
- **The changes page.** Every slot published with a base also gets `__flosis/changes.html`. It is a plain static
  page in the look of the repo's own nav (light, system font, no script). It shows:
  - the title (`<KEY> · <thread title>`);
  - a status line: `In progress` for a thread's branch, or `Accepted 21 Nov 2026 · 9f3c2a1` (every merge sha after
    more than one acceptance);
  - New and Updated per context, each screen linking to its page, with a small `changes` link to its `.changes.html`;
  - the line `Through shared components: …`.
- **The lasting link.** `/<org>/<project>/<KEY or task-<id>>/design` opens that changes page in the task's slot;
  with a page after `design/`, that page. The task's slot is:
  - the slot of the task's newest DesignMerge whose slot is published (each merge records its slot);
  - else its thread's branch (today's resolution);
  - else the key (unchanged).

  So the link shows the work in progress before the first acceptance, and the accepted version after it, until the
  next acceptance republishes the slot.
- **The link survives the thread.** It resolves through the task's merges, which keep their task, so it outlives a
  thread that is deleted, purged or unlinked from its task. Delete stays allowed on a reopened thread: its open work
  goes to the archive as today, and the accepted copy and its links stay. Accepted copies are never unpublished.
- **Jira web links.** The overview web link (Designs::JiraLinks) becomes this clean link, so Jira opens the changes
  page too. Screen links stay as they are.
- **Threads merged before this ships.** They have no accepted copy and resolve as today. No backfill.

### 5. Finished threads, and Reopen

- **The list.** Open threads as today, then **FINISHED · n**: merged threads, newest acceptance first, at opacity
  .55 (.8 on hover). Each row has:
  - a check icon, the title, and the task key chip (or NO TASK);
  - `Accepted <ago> · <sha>`, or `Merged <ago> · <sha>` without a task.

  Deleted stays last. The thread filter covers Finished rows.
- **A finished thread opened.**
  - Header: `✓ Accepted · <sha>` (or `Merged · <sha>`) with the date, and the buttons **Open designs** (the lasting
    link, new tab; task threads only) and **Reopen**.
  - Canvas modes: **Accepted | Changes**, on the accepted copy. A thread merged before this ships falls back to its
    branch copy, else master, as today.
  - The conversation is read-only. Where the composer was: `Accepted into master as <sha>. Reopen to change the
    designs again. Until you accept again, the link and <KEY> show this version.` Without a task: `Merged into master
    as <sha>. Reopen to change it again.`
- **Reopen** (POST `reopen`) refuses while turns run. Under the repo's lock it points the branch at master's head,
  here and on GitHub. That is a fast-forward, since the old head is in master: no force, nothing lost. Then:
  - the thread is open again, with `base_sha` = that head; `merged_sha` stays as the last accepted commit;
  - the note `Reopened by <name> · branch from master <sha>`;
  - the next message is an ordinary design turn, with proposals allowed (variant b).
- **The task's Designs strip.**
  - An accepted thread: `✓ Accepted · <sha>`, **Open designs** (new tab), **Open in Designs**.
  - A reopened thread: as an open thread today, plus a small `Accepted · <sha>` link to the lasting link.

### 6. The modal on the task

- It shows once per acceptance: for the newest merge of the task's thread that has its description version and has
  not been shown. Showing it stamps the merge (`announced_at`), whoever opens the task first. It opens on the Details
  stage through `clar-modal`'s open value.
- Content (mockup v2, step 3):
  - the heading `Designs accepted`;
  - `Description updated · v<n>`, then `Added Designs: the link, the merge commit and the <N> changed screens.`;
  - then one of:
    - `Changed to match the designs:` and the bullets;
    - `Nothing else needed changing.`;
    - the fallback line.
  - `Designs linked`: the lasting link (new tab) and `· the accepted version, in a new tab`;
  - the **What's left** box:
    - `A branch with the task for the developer to take over, and the Jira ticket updated with the new description.`
    - with no ticket yet, the end reads `… and a Jira ticket created with the new description.`
    - with no GitHub repo, only the Jira half;
    - under it, in mono: `<branch> · tasks/<KEY>/<key>.md`.
  - buttons **Later** and **Finish** (label as in §7).

### 7. Finish

- **Where.** It replaces **Finish · go to Ready** in the Details panel of every task, designed or not (Kacper's
  answer (a): the task file helps any task), and is the modal's button. Only a project with neither Jira nor a
  GitHub repo keeps today's local-only Finish. The label depends on the project and the task:

  | Situation | Label |
  |---|---|
  | Ticket + GitHub | Finish · Update Jira & Create branch |
  | No ticket + GitHub | Finish · Create Jira ticket & branch |
  | Branch already created | Finish · Update Jira & branch |
  | No GitHub repo | Finish · Update Jira / Finish · Create Jira ticket |
  | No Jira and no GitHub | Finish · go to Ready (as today) |

- **What it does** (POST `finish`, in the request):
  1. **Jira**, when the project has it: `JiraWriter#commit_detail(current Details version)`. This updates the ticket,
     or creates it and gives the task its key, and marks AI actions Detailed. On failure the person stays on Details
     with `Couldn't write to Jira: …`, and nothing else happens.
  2. **The branch**, when the project has a GitHub repo and token: one commit, through the Git Data API, holding
     `tasks/<KEY>/<key>.md` and `tasks/<KEY>/attachments/<files>`.
     - Name: `task.code_branch`, else `Task#suggested_branch`, with the key no longer repeated when the name starts
       with it (`feat/scrum-70-add-token-calculations`).
     - Base: `project.github_branch`, else the repo's default branch.
     - Once the branch exists, a later Finish adds a commit on top, only when a file changed, and never forces.
     - Files the task no longer has leave the folder.
     - Commit message: `<KEY>: task description v<n>`.
     - On success the branch, commit and time go on the task.
     - A failure is recorded on the task with GitHub's reason, for example `The project's GitHub token can't write to
       RubyOnSaas-wiki/clar (403). It needs Contents: write — Configuration › GitHub.`
  3. **Ready**: the task moves to Ready (after a Jira write, as `push_jira` does). This happens even when the branch
     failed: Ready shows why, with **Create branch** to try again.

  Toast: `Jira updated · branch <name> created` (or what happened).

### 8. The task file

`tasks/<KEY>/<key>.md` (KEY: the Jira key, else `task-<id>`; the file name is the key in lower case):

```
# <task name>

Description v5 · 21 Nov 2026 · from Flosis
- Jira: <issue url>
- Designs (sign in to Flosis): <lasting link>
- Design code: https://github.com/<design repo>/commit/<sha>      (one per acceptance)
  The screens this task changed, in that repo: designs/admin/consumption.html, … (all of them)
- Attachments: attachments/ (2 files)                            (left out when none)

<the current Details version, in Markdown>
```

- An HTML version (the rich-text editor saves HTML) is converted to Markdown.
- The attachments are the task's own (synced from Jira), under their filenames made safe; a duplicate name gets a
  number.
- A file over 50 MB is listed, not copied.

### 9. Ready

- **Designs tile.** `Accepted · <N> screens`, linking to the lasting link in a new tab, when the thread has been
  accepted; else today's copy.
- **Branch card.**
  - Created: `Branch created · ON GITHUB`, the `git checkout <branch>` line with Copy, **Open on GitHub**, and `In it:
    tasks/<KEY>/<key>.md (description v<n> with the designs' links). Tell your AI: “read tasks/<KEY>/<key>.md”.`
  - Not created and GitHub configured: the name, the last error if any, and **Create branch**.
  - No GitHub: the suggested name under `Suggested branch`, without the claim that anything is committed.

### 10. Jira gets Markdown

`JiraWriter.plain_text` converts an HTML version to Markdown (headings, bold, italics, lists, links, code, breaks)
instead of stripping its tags; Markdown passes as it is. MarkdownToAdf already renders headings, bold, bullets and
links. Today an HTML version reaches Jira flattened, and its links lose their addresses.

## Data

- `design_merges`:
  - `slot` string (`accepted/<thread id>`);
  - `description_version` integer;
  - `description_changes` JSON;
  - `described_fallback` boolean, default false;
  - `announced_at` datetime.
- `tasks`:
  - `code_branch` string;
  - `code_branch_sha` string;
  - `code_branch_pushed_at` datetime;
  - `code_branch_error` text.
- Code-only changes, no migration:
  - VersionableDocument: the origin `designs`, labelled `Designs accepted`.
  - DesignTurn: the kind `describe`.
  - Publisher::SLOT: `accepted/<digits>`.

## Calls I made

1. The Designs section sits under the intro, not at the end (the mockup Kacper approved).
2. The describe step is a turn of the thread (visible progress, Try again, stale handling), not a bare job.
3. When the AI fails, v<n> still comes, with the Designs section only, and the modal says so.
4. The modal shows once per acceptance, to whoever opens the task first.
5. A thread without a task keeps Merge, but its merge is published and it lists under Finished.
6. Over two or more acceptances, a screen's changes are marked against master before the first one. A screen another
   thread changed in between shows that change too (rare).
7. Finish moves the task to Ready even when the branch fails, because Jira is written by then. Ready says why and
   retries.
8. Attachments over 50 MB are listed, not copied. Chat images are not copied.
9. The branch base is the project's configured branch, else the repo's default (for Flosis that is `main`, which
   gets production's tree after every ship; set the project's branch to `production` to base on the trunk).
10. Jira's web links stay alongside the description's links.
11. Accept is not refused when the description is ahead of the designs. The dialog warns, the newer text wins in the
    AI's edit, and a reopened thread still offers Update designs for it.
12. The Designs section is guaranteed where the description leaves Flosis (Jira, the task file), not in every
    version in the panel; the Details AI is told to keep it.
13. The lasting link resolves through the task's merges, so deleting or unlinking a thread never breaks it.
14. On a task with no Details version, acceptance makes Details v1 from the current text (the brief), with no v0.
15. Screens with the same name before ` — ` are grouped in the Designs section, as in the mockup.

## Left to the builder

- The prompt's exact wording within §2's rules.
- How the change page looks, within “plain, like the repo's nav”.
- How the redirect after the describe turn is wired, as long as it reaches only the person who accepted, once.
- Names of jobs, services and the GitHub client's new methods.
