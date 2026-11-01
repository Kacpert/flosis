# Workshop Designs v2 — Design

**Status:** draft for Kacper's approval, 2026-11-02.

**What it replaces.** This document replaces four parts of `2026-10-30-workshop-designs-design.md` (the "v1 spec"):
- the Designs screen;
- the setup run;
- the Configuration › Designs tab;
- the branch model.

Everything else v1 decided still stands, unless this document says otherwise:
- the client's GitHub gets only the design files;
- prompts and skills are Flosis IP;
- API keys;
- previews live under app.flosis.com.

**Sources of truth for screens and behaviour:**
- **Kacper's design:** `2026-11-02-designs-v2/ClearBacklog-3.html`, a single-file React prototype. To use it, open it in a browser, sign in with "Continue with Atlassian", then click Designs.
- **The approved mockup:** `2026-11-02-designs-v2/ClearBacklog-3-master-changed.html`. It adds the one state the design lacks: master moving on under an open thread. Kacper approved it on 2026-11-02.

## Why a second version

v1 reached production on 2026-10-31 (release 20261031173533). When Kacper saw it, he said it was completely different from what he meant, and he drew the screens himself. His design changes the model, not just the look:

- **Threads.** Design work happens in threads. Each thread is a branch from master with its own conversation, and a task is optional. v1 had one conversation per task.
- **A module of its own.** Designs is a full-screen module that shows, in one place:
  - the whole design (master);
  - every open thread;
  - the design system;
  - the components;
  - the merge history.

  v1 had a chat-and-preview screen per task.
- **Merges.** Master changes when a thread is merged into it, by hand or automatically when the linked Jira task is Done. v1 had an approval per task.
- **Setup.** Setup is a form in the product, followed by one long background run that rebuilds today's app 1:1. v1 had a three-phase run that Flosis staff reviewed.
- **A chosen stack.** Designs are written in one of four stacks: Vue, React, Angular, or plain HTML + CSS. A UI system (Tailwind and others) sits on top. Flosis's own designs are HTML + CSS, close to v1's static designs. v1 offered no choice.

## Goals

1. **Reproduce `ClearBacklog-3.html` faithfully.** That means every screen, state, button and line of copy listed in "The screens, item by item". The prototype's sample data (a fictional recruitment app) is replaced by the project's real data.
2. **Show changes and let people bring them in.** The person sees when a thread's task description changes, and when master moves on under an open thread. Both show in Designs, on the task and in the pipeline. Either change comes in with one click.
   - The description change is designed in `ClearBacklog-3.html`.
   - The master change follows the approved mockup.
3. **Work end to end on the pilot.** The pilot is Flosis's own project (Gold): HTML + CSS with Tailwind v4.
4. **Keep the v1 guarantees:**
   - the client's GitHub gets only the design files;
   - Flosis's prompts never leave Flosis;
   - previews open only for signed-in people who can see the project, and they open sandboxed.

## Non-goals (this version)

- **The staff Admin panel "above everything".** It would hold MCP tools and each client's AI settings. Kacper: "on teraz nie jest potrzebny ale w przyszłości to zrobimy".
- **Flosis running the setup for clients, and redesigning the setup logic.** Kacper: "na razie zróbmy to tak jak jest w designach a później omówimy logikę".
- **Vue, React and Angular previews.** The setup form shows them, but they cannot be picked yet (Claude's call 3).
- **Other stacks.** Svelte and Rails views are not offered at all. Kacper: "nie robimy widoków erb te to po prostu będą html + css są vue angular i react lub html i css innych rzeczy nie robimy".
- **Figma, uploaded materials and brand inputs as setup inputs.** v1 had them; the design has none.
- **Notifications outside the app**, such as email or Discord.

## Anti-goals (a failure even if everything else works)

- A screen, state or line of copy from the design is missing, or reworded without a ruling in this document.
- Anything in a design repo runs as code on the Flosis server. An AI writes the designs, and it reads task descriptions and chat messages that anyone on the project can steer.
- A person sees designs of a project they cannot see, or a preview runs with the app's cookies.
- Master changes without a merge that the merge history records.
- An open thread falls behind master, or behind its task's description, without saying so.

## Decided by Kacper

1. **2026-11-01** — His design is the source of truth, details included: "tam jest dużo szczegółów jak to ma działać upewnij się że odwzorujesz designy".
2. **2026-11-01** — Designs shows when the task description changes and when master changes: "że będziesz pokazywał w designach jak się zmieni opis taska lub master z designów".
3. **2026-11-02** — The master-change mockup is approved: "tak wygląda ok".
4. **2026-11-01** — The staff Admin panel comes later. What staff configure (MCP tools, AI settings) moves there when it exists.
5. **2026-11-01** — Setup works as in the design for now. A person fills in the form. Then a long run scans the repositories and walks the screens, building the design system, components and screens so that they reproduce today's app 1:1. Flosis will probably run setup for clients later, and that logic is for a later discussion.
6. **2026-11-02** — The pilot is Flosis (Gold), the project where Kacper tests every feature first.
7. **2026-11-02** — The stacks are Vue, Angular, React, or HTML + CSS. Nothing else, and no ERB views: the pilot's designs are HTML + CSS.
8. **2026-11-02** — Once the spec is ready, implementation starts straight away, inline: "jak będziesz miał już speca to możesz od razu inlinowo kodować".
9. **2026-10-31** (from v1, still standing) — Design links live under `app.flosis.com/<organization>/<project>/…`. There is no separate preview domain.
   - `…/design/…` is master.
   - `…/<KEY>/design/…` is a task's design.
   - Both send a signed-in reader who has access on to `…/<grant>/design/…`, which is served sandboxed.

## Words

- **Master** — the approved design of the whole app. It is read-only.
- **Thread** — a branch from master plus its conversation with Flosis AI. A thread is open until merged; a merged thread is read-only.
- **Context** — a role the app is seen as, such as the design's Candidate, Recruiter and Admin. Each context has its own folder of screens.
- **Screen** — one page of the app in one context.
- **Merge** — a thread landing on master. Three things can merge one:
  - a person: "Manual · <name>";
  - its task reaching Done: "Auto · <KEY> moved to Done";
  - the setup: "Flosis AI · setup".

## How it works

### The design repo

```
README.md        how developers and their AI use the repo (Flosis template, no Flosis IP)
index.html       entry point (Flosis template)
runtime/         what the browser needs: Flosis's runtime and the UI system's kit (Flosis template)
design-system/   tokens and styles extracted from the app: colours, type, spacing, radius
components/      the app's building blocks, rebuilt in its stack; screens are composed from them
designs/         one folder per context (designs/admin/, …); one file per screen
inspirations/    references the AI may borrow from: screenshots, links, notes; never shipped
```

- **The four folders come from the design.** Their names and descriptions are the design's (Design settings › Structure), and they are what turns may change.
- **Flosis owns the rest.** `README.md`, `index.html` and `runtime/` come from the Flosis template, as in v1, so the repo opens from any static file server with no build step.
  - Only Flosis's own commits (the template and the setup) write them.
  - The leak guard refuses a turn that touches them, or anything outside the four folders.
- **Files are in the project's stack.** For HTML + CSS:
  - a screen is `designs/<context>/<screen>.html`;
  - a component is `components/<name>.html`, which a screen pulls in with v1's `<x-include src>`;
  - styles and tokens are in `design-system/`.

  The canvas and the merge dialog show the real paths, for example `designs/admin/pipeline.html`.
- **Fake data is written into the screens.** They are static pages with realistic content, as v1's are.
- **Folders and files decide what exists.**
  - A context exists if it has a folder.
  - A screen exists in a context if it has a file in that context's folder.
  - "View as" offers the contexts the current screen exists in.
- **Screens link to each other** with plain relative links within a context folder, so the prototype stays clickable from screen to screen.
- **The library pages have data to read.** The repo holds the tokens in a machine-readable file for the Design system page, and one example per component for the Components page.

### Threads and branches

- **A thread is a branch from master.** The branch is named when the thread gets its first message:
  - `design/<KEY>-<slug>` when the thread is linked to a task at the start;
  - `design/<slug>` otherwise;
  - the slug is the first four words of the change;
  - a task without a Jira issue yet uses `task-<id>` as its key;
  - a branch keeps its name when its task gets a Jira key later (Claude's call 9).
- **A thread remembers three things:**
  - the master commit it is based on, so it knows how far master has moved since;
  - the task description version it last designed from, so it knows whether the description has changed;
  - its focus (the screen and context it last worked on), so it opens there.
- **One thread per task, ever.**
  - A task's strip offers "Design with AI" until the task has a thread, and "Open in Designs" after that.
  - "Link to task" in the New thread dialog lists only the project's pipeline tasks that have no thread.
- **Commits ahead and merges behind come from git.**
  - Commits ahead: the commits on the branch since its base.
  - Merges behind: the merges on master since that base.
- **Branches are never deleted.** A merged thread stays readable, and its branch stays where the developer convention expects it.

### Previews

- **Flosis publishes each branch whenever it moves,** as today:
  - the branch's files, unchanged, under `DESIGNS_PREVIEW_ROOT`, one folder per branch;
  - served by `Designs::PreviewsController` behind a grant;
  - sandboxed with `allow-scripts allow-forms allow-popups allow-modals` and no `allow-same-origin`.
- **Nothing in a design repo runs on the server.** HTML + CSS needs no build: the browser resolves `<x-include>` and loads the UI system's kit, inside the sandbox.
- **The UI system's kit runs in the browser,** as v1's kits do (Claude's call 2):
  - Tailwind v4 compiles in the browser from the tokens and styles in `design-system/`;
  - Custom is plain CSS.
- **Flosis's runtime (`runtime/flosis.js`) gains three jobs.** It talks to the canvas with `postMessage` only.
  - It tells the canvas which screen and context are showing, which drives "AI sees <Context> › <Screen>".
  - It turns a click on a screen that is not designed into the design's toast. Flosis publishes the list of screens beside each branch (never committed), so the runtime knows which exist.
  - It draws the Changes outlines.
- **Links.**
  - **"Open in new tab"** opens the current branch, context and screen under a grant: `/<org>/<project>/<grant>/design/<context>/<screen>`.
  - **Master's lasting link** is `/<org>/<project>/design/<context>/<screen>`.
  - **A task's lasting link**, the one Jira gets, is `/<org>/<project>/<KEY>/design/<context>/<screen>`. It shows the task's thread branch, merged or not.

### Changes

- **Changes compares the branch with master, screen by screen.** Each screen is compared with its components pulled in. Flosis expands `<x-include>` on the server the way the runtime does, as text, so nothing runs.
  - A screen that differs is listed in "Changed in this thread".
  - An element that master lacks gets the dashed outline labelled NEW.
  - An element that differs from master gets UPDATED.
  - A screen that master lacks is NEW as a whole.
- **Chips under an AI reply** list the screens that turn changed: "M Candidate › Application form", or "+ …" for a new screen. Flosis computes them by comparing the screens before and after the turn; the AI does not report them.

### When the task description changes

As designed:
- the thread row shows "Task changed";
- the conversation shows the banner "<KEY> changed since the last design update (vX → vY)." with "Update designs";
- the task strip shows "Description changed since the last design update" with "Update designs from diff";
- the pipeline card shows "Designs need update".

The versions are the task's description versions: its Details drafts, or its Brief before Details exists.

**"Update designs" is an ordinary turn** whose message is the change. After it:
1. The conversation first shows the diff block "<KEY> description changed · vX → vY". Removed lines are struck through in red; added lines are green.
2. Then comes the AI's reply, with chips.
3. The canvas switches to Changes.

### When master changes

As in the approved mockup:
- **The thread row** shows "Master changed".
- **The header** says "<n> commits ahead · <m> merge(s) behind master".
- **The banner** says "master changed since this thread branched (<base> → <master>)."
  - It lists the merges since the base, each with its title and what changed. Clicking a merge opens it in Merge history.
  - It shows at most three merges, then "and <n> more".
- **"Update from master"** does five things:
  1. Flosis merges master into the branch.
  2. The conversation shows the green block "master <base> → <master> brought into this branch", listing those merges.
  3. A turn has the AI check the thread's screens against what came in, and adjust them. Its reply names what it adjusted, with chips.
  4. The canvas switches to Changes.
  5. On a conflict, the same turn resolves it first, as v1's resolve-conflicts turn does.
- **The task strip** shows "Master changed since the thread branched" with "Update from master".
- **The pipeline card** shows "Designs need update".
- **"Merge into master?" warns** when the thread is behind: "master changed since this thread branched. Update from master first to see the result before it lands."
- **Every open thread falls behind at once** when master moves, and nobody has to refresh.

### Merging into master

**By hand.** "Merge to master" opens "Merge into master?", which lists the changed screens and their files. Merging:
- writes a merge commit on master;
- records the merge;
- publishes master;
- adds "Merged into master as <hash> by <name>" to the thread;
- opens Merge history with the new merge expanded.

After that the thread is read-only.

**On Done.** When Jira sync sees a thread's task move to the Done status category, Flosis merges the thread as "Auto · <KEY> moved to Done". That is the moment `Task#status` becomes `done`.
- If master has moved, Flosis brings it in first.
- On a conflict it does not merge. The thread says: "Couldn't merge automatically: master changed the same lines. Update from master, then merge." (Claude's call 8.)

**The merge summary** (Summary and What changed in Merge history) is written by the AI from the thread, right after the merge.

**Merges run one at a time** under the repo lock, and each waits for its thread's running turn, as v1's approvals do.

### Tasks and threads

**"Design with AI"** on a task starts that task's thread.
- The AI reads the current description and compares it with master.
- It updates the screen that covers the change, or drafts a new section where nothing does.
- The design's wording for the first message is the example the prompt follows.

**"Generate task"** appears in a thread with no task. It opens a dialog with a title and a description that the AI wrote from the conversation and the changes. The description has:
- the goal;
- the scope, with the changed screens;
- the line `Designs: <repo> @ <branch> (merges into master when this task is Done)`;
- open questions for Details Gathering.

Creating the task:
- puts it in the pipeline at Details, with that description as its first version;
- links the thread;
- opens the task, where:
  - Briefing says "This task was generated from a design thread, so the brief is covered by the conversation and the designs.";
  - Details opens with "I wrote this description from the design thread, so I already know the scope and which screens change. I'll ask only the product questions that are still open, one at a time."

**The task strip** sits under the stage stepper on every stage, as designed, with the master states added.

**The pipeline card badge** says "Design thread", "Designs need update" or "Designs merged", and it opens the thread.

**Jira.** When a task with a thread is pushed or synced, its description carries:
- the lasting links to its changed screens;
- the line naming the repo and the branch.

This is what v1's Jira links do.

### Setup and re-import

**The form is the design's.** It has three cards:
1. **Technology:** framework, UI system and their versions.
2. **Repositories:**
   - the designs repository, plus the token field that Claude's call 4 adds;
   - the read-only app repositories.
3. **Staging and contexts:** name, login URL, login and password for each context.

Passwords are encrypted and never shown again.

**"Build designs" starts one background run.** It reuses v1's crawler and setup prompts, unattended. It runs the design's seven steps, each with a time estimate:
1. Reading <repos>.
2. Signing in to staging as <contexts>.
3. Capturing pages for every context.
4. Extracting design tokens from <UI system> settings.
5. Building components in <framework>.
6. Generating screens across <n> contexts.
7. Committing to <repo> @ master.

The run also flags a mismatch between the chosen stack and the app's lockfiles.

**While it runs:**
- the progress page shows the percentage, "About <n> min left" and each step;
- the Designs item in the sidebar blinks;
- the person can leave the page.

**When it ends,** it commits straight to master as "Initial import from staging" ("Flosis AI · setup"). The person who started it sees the toast "Designs ready · <project> @ master" on their next page.

**A failed step** stops the run. The progress page then shows the step, its error and "Retry". This state is not designed, so it uses the progress page's style.

**"Edit setup" and "Re-import"** run the same import on a thread, "Re-import from staging". That thread is reviewed and merged like any other (Claude's call 5).

### Claude turns

v1's runner stays as it is:
- one background job per message, on the `designs` queue;
- file tools only;
- the project's API key, a cost cap and a time limit;
- Flosis commits, pushes and publishes;
- a failed turn leaves the branch at the last good commit.

A turn gets three new inputs:
- the screen and context the person is looking at;
- the inspirations the person attached, which are committed to `inspirations/` on the branch;
- for the two update turns, the description diff or the merges that came in.

The prompt and the stack guidance live in the Flosis library, as in v1.

### Permissions

- **A new Designs permission** sits next to Tasks.
  - It is on by default for Product Owners and Administrators, and off for Project Managers.
  - The Users tab's "Designs" switch says "Product Owners and Administrators by default", and the defaults line names Designs.
- **Designs gates** the Designs module, the task strip and the pipeline badges.
- **Configuration gates** the setup form, "Edit setup" and "Re-import". The settings drawer says "Changing these needs the Configuration permission."

## The screens, item by item

Everything here is in `ClearBacklog-3.html` unless it is marked:
- *(mock)*: from the approved master-change mockup;
- *(ruling)*: a call this document makes.

Copy is verbatim; `<…>` is filled in.

### Sidebar
- "Designs" sits between Create Tasks and Reporting, with the pen icon.
- It has a blinking dot while a build runs, titled "Building designs in the background".

### Setup form (a project without designs)

**Title and intro.**
- Title: "Set up Designs for <project>". When editing: "Edit Designs setup", with "‹ Designs" to go back.
- Intro: "The AI reads your repositories, signs in to staging as each context, and builds the design system, components and today’s screens in the designs repository. It runs in the background and usually takes about an hour. After that, every change happens in threads."

**Card 1, "Technology":** "What the designs are built with. Components are generated in this stack and version."
- FRAMEWORK chips: Vue.js, React, Angular, HTML + CSS, with a VERSION field. Kacper set these four on 2026-11-02, in place of the design's Svelte and Rails views.
- UI SYSTEM chips: Foundation, Bootstrap, Tailwind, Material, Custom, with a VERSION field.
- "The AI checks these against package.json and the lockfile and flags a mismatch."
- *(ruling)* Vue.js, React and Angular, and every UI system except Tailwind and Custom, are disabled and labelled "Soon". HTML + CSS has no version field.

**Card 2, "Repositories":** "Where the designs are stored, and the product code they are based on."
- DESIGNS REPOSITORY (TARGET): "The AI commits here. master holds approved designs; each thread is a branch."
- *(ruling)* A token field sits under it.
- CURRENT APP REPOSITORIES · READ-ONLY: rows with role, URL and remove.
- "Add repository".
- "Frontend, backend, shared UI library… The AI uses them to match real components, copy, routes and data."

**Card 3, "Staging and contexts":** "The AI signs in as each context to capture what that role sees. Each context can have its own login page. Use test accounts."
- Columns: CONTEXT, LOGIN URL, LOGIN, PASSWORD, remove.
- "Add context".

**Footer.**
- The hint reads "About an hour, in the background. You can keep working." when the form is complete. Otherwise it reads "Fill in the designs repository, at least one app repository and one context with URL and login."
- The button is "Build designs", or "Save and re-import" when editing.
- Toast: "Building designs in the background · about an hour".

*(ruling)* **Without Configuration,** there is no form, only: "Designs isn't set up for this project. An administrator sets it up."

### Build progress
- "Running in the background" (blinking).
- "Building designs for <project>".
- "This usually takes about an hour. You can leave this page and keep working. We’ll notify you when master is ready."
- A card with:
  - "<n>%" and "About <n> min left";
  - a progress bar;
  - the seven steps, each done ✓, current (blinking) or pending, with "~<n> min".
- "Back to <where they came from>" or "Continue working".
- *(ruling)* **A failed run** shows the step in red, its error and "Retry".

### The module
- Two columns: the panel (280–340px wide) and the canvas.
- "Hide menus" hides the top bar and the sidebar.
  - It is on by default, as designed. *(ruling)* It is remembered per browser.
  - Tabs on the top and left edges let the person peek at the hidden menus: "Show top bar" / "Hide top bar", "Show menu" / "Hide menu".

### Panel: the list
- "‹ Back to <task or page>", when Designs was opened from elsewhere.
- **Header:**
  - "Designs", the menu toggle, and the settings gear ("Design settings");
  - "Synced <time> · <repo>";
  - the "Hide menus" switch.
- **Library links, each with its count:**
  - "Design system — Colours, type, spacing, radius";
  - "Components — <n> in <framework>";
  - "Merge history — <n> merges into master".
- **The branch list:**
  - "BRANCHES · <open threads + 1>" and "+" ("New thread");
  - "Filter threads", when more than five threads are open.
- **The master row:** the lock icon, "master", "Read-only", "Last merge <hash> · <when>".
- **Thread rows:**
  - the title;
  - the task key, or "NO TASK";
  - "Task changed";
  - "Master changed" *(mock)*;
  - the updated time.
- **At the bottom:** "No open threads." when there are none, and "New thread".

### Panel: a thread

**Header:**
- "‹ Threads", "Hide menus" and the menu toggle;
- the title and the branch pill;
- one of:
  - "<n> commits ahead", plus " · <m> merge(s) behind master" *(mock)*;
  - "No changes yet";
  - "Merged · <hash>".

**The task line:**
- "<KEY> · <stage>", which opens the task, or "Generate task";
- "Merges automatically when <KEY> moves to Done." or "Generate a task when the scope is clear. It starts in Details Gathering."

**Banners:** task changed; master changed *(mock)*.

**Messages:**
- system lines, with the branch icon:
  - "Thread started from <KEY> · branch <branch> created from master <hash>";
  - "Branch <branch> created from master <hash>";
  - "Merged into master as <hash> by <name>";
  - "Task <KEY> created from this thread · Details Gathering started";
- the description diff block;
- the master block *(mock)*;
- a person's message, with avatar and name;
- "Flosis AI" replies, with chips;
- the thinking dots while a turn runs.

**The composer:**
- The placeholder is "What should change? Navigate the app on the right, AI sees the page you’re on." on a new thread, and "Describe a change…" otherwise.
- "AI sees <Context> › <Screen>".
- The attach button ("Attach inspiration") shows the toast "Add screenshots or links · saved to inspirations/". *(ruling)* It opens a file and link picker.
- Send: Enter sends, and Shift+Enter starts a new line.

**A merged thread** shows "Merged into master as <hash>. Start a new thread for further changes." instead of the composer.

### Canvas
- **The toolbar:**
  - "View as" with the contexts; a context where the screen does not exist is disabled ("Not available for <Context>");
  - on an open thread: "This branch / Master / Changes";
  - "Open in new tab", with the toast "Opened in new tab · <url>";
  - "Merge to master" on an open thread, or "Read-only · start a thread to change it" on master.
- **Changes:** the strip "Changed in this thread", with a chip per screen, and the NEW and UPDATED outlines.
- **The frame:**
  - three dots and `designs/<context>/<file>`;
  - the pill `master` (lock, green) or the branch name (purple);
  - the page, 1160px wide, scaled to fit.
- **Inside the page:**
  - a link to a screen that is not designed shows the toast "<label> is not designed yet. Start a thread to add it.";
  - a link to a screen not designed for this context shows "<label> is not available as <Context>".

### Library pages
- "‹ Back to canvas · <branch>".
- **Design system:** "On master. Extracted from <app repo> and <n> staging pages on <date>. Token changes go through threads like any other design change."
  - Cards: Colours, Typography, Spacing, Radius, each naming its file.
- **Components:** "On master. Built in <framework> with <UI system> classes, matched against <app repo>."
  - One card per component: preview, name, file, and "Used in <n> of <m> context views".
- **Merge history:** "Threads merged into master, newest first. Click a merge to see what went in."
  - Each row: hash, title, "<branch> → master", how, "<n> screen(s)", when.
  - An expanded row adds:
    - SUMMARY;
    - WHAT CHANGED;
    - SCREENS chips, or "All screens";
    - "Task <KEY>";
    - "<n> commits · <how>".

### Design settings (drawer)
- "Design settings" and "Per project · <project>. Changing these needs the Configuration permission."
- **REPOSITORY:**
  - Designs repository;
  - Branch: `master` "read-only", or the thread's branch "from master <hash>". When the thread is behind, " · master is now <hash>" is added *(mock)*;
  - each app repository, "read-only · current product code";
  - Sync: "Synced <time>".
- **STACK:** Technology, UI system, Styles.
- **STRUCTURE:** "What each folder in <repo> holds. The AI follows this when it changes designs." Then the four folders, with the design's descriptions.
- **INITIAL SOURCES:** "Where the designs came from. The AI used these to build the design system, components and screens."
  - each context's login URL, and "<login> · ••••••••";
  - App code: "<repos> @ master";
  - Captured: "<n> pages · <date>".
- **Buttons:** "Edit setup", and "Re-import" with the toast "Re-import queued · staging and <app repo>".

### Dialogs

**New thread:** "A thread is its own branch from master. Describe the change and AI drafts it. Keep talking until it’s right, then merge it or generate a task."
- WHAT SHOULD CHANGE?, with a placeholder example. *(ruling)* The design's ATS example is replaced by an example from the project.
- START ON: context › screen.
- LINK TO TASK: "No task yet", plus the tasks without a thread.
- "Cancel" and "Start thread".
- Toast: "Thread started · <branch>".

**Generate task:** "Written from this conversation and the design changes. The task starts in Details Gathering with this description."
- TITLE and DESCRIPTION.
- "Linked to <branch>. The thread merges into master when the task is Done."
- "Cancel" and "Create task · start Details Gathering".
- Toast: "Task created · <title> · Details Gathering".

**Merge into master?**
- The branch → master.
- CHANGED SCREENS: context › screen, and the file.
- The behind-master warning *(mock)*.
- One of:
  - "If you don’t merge now, this thread merges automatically when <KEY> moves to Done.";
  - "This thread has no task, so it only merges when you merge it."
- "After merging, master stays read-only and further changes need a new thread."
- "Cancel" and "Merge into master".
- Toast: "Merged into master · <hash>".

### Task page and pipeline

**The strip** sits under the stepper on every stage. It shows "Designs" and, depending on the thread:
- an open thread: the branch pill and "merges on Done";
- a merged thread: "Merged into master · <hash>";
- a changed description: "Description changed since the last design update", with "Update designs from diff";
- a changed master: "Master changed since the thread branched", with "Update from master" *(mock)*;
- "Open in Designs", or "Design with AI" when there is no thread yet:
  - on a project without designs, "Design with AI" goes to the setup, with the toast "Set up Designs for <project> first";
  - otherwise it starts the thread, with the toast "Design thread started · <branch>".

**The pipeline card badge** says "Design thread", "Designs need update" or "Designs merged", and it opens the thread.

### Users
- The "Designs" switch, with "Product Owners and Administrators by default".
- The defaults line: "Product Owner: those plus Designs and Briefing Configuration".

## What happens to today's code

| Today (v1) | v2 |
|---|---|
| `Designs::Repo`, `Committer`, `LeakGuard` | Kept. The guard's allowed paths become the five above. |
| `Designs::PreviewGrant`, `PreviewsController`, `PreviewEntriesController`, routes | Kept. Slots become branch names. |
| `Designs::Publisher` | Kept for publishing. It gains the screen list and the Changes variant. |
| `runtime/flosis.js` | Kept. Contexts come from folders instead of `?ctx=`, and it gains the three new jobs. |
| `Designs::TurnJob`, the `designs` queue and worker | Kept. Turns belong to threads. |
| The crawler (`lib/designs_crawler`, `CrawlJob`), `SetupPrompts` | Kept, driven by the unattended setup run. |
| The library (entries, versions, staff page) | Kept as is and staff-only, until the Admin panel. |
| `DescribeJob`, `JiraLinks` | Kept, fed from threads. |
| `Designs::Template` (static runtime, `<x-include>`, kits) | Kept and adapted: `design_system/` becomes `design-system/`, contexts become folders, and `inspirations/` is added. |
| `WorkingBranch` (`contexts.json`, task manifests) | Replaced: contexts are folders, and screens are files. |
| `Approval`, `DesignApproval`, the `design/<KEY>`, `wip/<KEY>` and `wip/setup` branches, approval tags, `RenameForJiraJob` | Replaced by merges of thread branches. |
| The per-task Designs screen, "Start in Designs" in New idea, the Workshop › Designs page | Removed. The module replaces them. |
| Configuration › Designs tab, the setup-run page and its inputs, "Rotate preview links" | Removed. The setup form and the settings drawer replace them. |
| `design_base_kit`, `design_style_pack_key`, `design_app_url`, `design_figma_urls` | Removed from the UI. The stack fields replace them. |

**Migration.** No project had Designs switched on in production when v1 shipped, so there was nothing to migrate. Check again before deploying v2.

## Claude's calls (please check)

1. **The repo keeps v1's template files** (`README.md`, `index.html`, `runtime/`) next to the design's four folders.
   - Why: the repo then opens on any static file server, with no build and no Flosis.
   - The drawer's Structure lists only the design's four folders.
2. **Tailwind v4 compiles in the browser,** inside the sandbox, as v1's kit does.
   - Why: the Tailwind command-line tool on the server could load plugins, and plugins run code.
3. **This version supports only HTML + CSS, with Tailwind or Custom.**
   - Vue.js, React, Angular, Foundation, Bootstrap and Material stay visible as designed, disabled and labelled "Soon".
   - Why: each of them needs its own browser runtime or build, and the pilot needs none of them.
4. **The setup form gets a token field for the designs repository.**
   - Why: the design has nowhere to put write access to that repo.
   - The app repositories are read with the project's GitHub token from Integrations.
5. **Re-import is a thread you merge,** not a rewrite of master.
   - Why: a rewrite would throw away merged designs that the app does not have yet.
   - The first import still goes straight to master, as designed.
6. **Setup and turns run on the project's API key,** from Configuration › AI. Without a key, "Build designs" says what is missing.
7. **The setup form needs the Configuration permission.** Without it, the page says an administrator sets it up.
8. **On Done, Flosis merges only when git can.** On a conflict, it leaves the thread open and says why.
9. **Branch names never change.** A task's Jira key may arrive after its thread starts. The Jira description names the branch, so nothing needs renaming.
10. **The AI writes each merge's summary right after the merge,** manual or automatic.
11. **The library stays where it is, staff-only,** until the Admin panel exists. Style packs and base kits disappear from the UI.
12. **"Hide menus" is remembered per browser,** and is on by default as designed.
13. **The task strip and the pipeline badges show only to people with the Designs permission.**
14. **Four states are not designed, so they are added in the design's style:**
    - a failed setup step;
    - the setup page without the Configuration permission;
    - the file and link picker for inspirations;
    - "and <n> more" in the master banner.

### Settled after the builder check (2026-11-02, also Claude's calls)

15. **"New thread" and "+" open an empty thread, as the prototype does.** Both buttons call `openNew`, and nothing in the design opens the New thread dialog.
    - The empty thread shows "No changes yet" and the composer "What should change? Navigate the app on the right, AI sees the page you’re on."
    - Its first message names the branch.
    - The dialog is not built.
    - A thread gets a task only through "Design with AI" or "Generate task".
16. **Only a task with a Jira issue merges on Done.**
    - A task that is not in Jira cannot reach Done, so its thread says "This thread merges when you merge it." instead of the Done line.
    - Its strip leaves out "merges on Done".
17. **Jira gets v1's Web links**, re-pointed at the thread's changed screens, plus one link to the branch. Jira sync overwrites descriptions, so the description is left alone. A generated task's description carries the "Designs: <repo> @ <branch>" line because the AI writes it there.
18. **An app repository can name its branch,** as `owner/name@branch`. Without one, it is the repository's default branch. Gold's trunk is `production`, so the pilot enters `…@production`.
19. **Flosis staff switch Designs on for a project** (v1's `designs_enabled`), until the Admin panel takes that over.
    - Until then, people outside Flosis staff see neither the Designs item nor the task strip.
    - Staff see the switch on the setup page.
20. **Re-import is a full rebuild on a thread.** People trim it in the thread before merging. The progress page and the sidebar dot show while it runs. Kacper will settle the setup logic later.
21. **Running the crawler on the production server is still unproven.** A crawl step that cannot start fails visibly, with "Retry". Whether to fall back to the code alone is decided when that happens.
22. **The setup asks for test accounts,** as the form says. For Flosis, Kacper chooses where the crawl signs in. Gold has no staging, and production holds real data that would reach the design repo.

## Left to the builder

- **Data and wiring:**
  - routes, model names and column names;
  - how threads use `ChatSession`.
- **Formats:**
  - the fake-data format;
  - the tokens file that the Design system page reads;
  - component examples.
- **Choices inside the features:**
  - how the HTML comparison picks NEW and UPDATED without noise;
  - the runtime's message format;
  - how the canvas updates while a turn runs: Turbo Streams or polling;
  - the toast mechanism for "Designs ready";
  - how the AI's merge-summary job is triggered.

## Risks to verify first

1. **Gold's screens may not come out 1:1 in HTML with Tailwind's browser build.**
   - Gold's styles use `@theme`, `@apply` and its `clar-` component classes.
   - Check: port two real screens by hand (the pipeline and the idea page), and compare them with the app.
2. **The unattended setup run may be too slow or too costly.**
   - The server is shared, and there is one `designs` worker.
   - Check: it should finish within an hour, at a sensible cost on the project's key.
3. **Jira sync may not see Done reliably.**
   - It runs every 15 minutes and maps the status category to `Task#status`.
   - Check: a task moved to Done in Jira reaches `done` in Flosis.

## Testing

- **Every line of "The screens, item by item" gets a test** that fails if the line goes missing. These are controller or system tests on the real screens.
- **The leak guard and the server-side include expansion** get a test for each thing they must refuse:
  - a turn that changes a path outside the four folders, or Flosis's own files;
  - an include cycle;
  - an include that leaves the repo.

  Each refusal is also checked by mutation: allow it, and see the test fail.
- **The thread lifecycle** is tested through each of these:
  - ahead and behind;
  - a description change;
  - update from master, clean and with a conflict;
  - a manual merge;
  - a merge on Done, clean and with a conflict.
- **Permissions:** Designs and Configuration, each on and off.
- **No real Claude CLI runs in tests,** as in v1.
- **At the end,** the production screens are clicked through side by side with `ClearBacklog-3.html` and the mockup, screen by screen, with screenshots.
