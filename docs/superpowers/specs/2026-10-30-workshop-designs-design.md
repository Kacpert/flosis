# Workshop Designs — Design

**Date:** 2026-10-30
**Status:** Approved (design), pending implementation plan
**Author:** Kacper + Claude

## Problem

Designs reach a Workshop task in two ways today, and both break:

1. **"Request from designer"** (optional, in Details). A human designer delivers
   Figma links, and `JiraWriter#sync_design_links` appends a `--- Designs ---`
   block to the task description. Figma frames are pictures: no states, no
   roles, no data. The developer translates them by hand, and the step waits on
   a person.
2. **Claude Design.** Designs live outside any repository. Every handoff or
   export is a downloaded snapshot that starts going stale the moment it is
   taken. On the Flosis landing every export silently reverted production
   fixes (Sign in links, favicon, localStorage key). That is why
   `script/build_landing.rb` now re-applies them on every drop. Standalone
   Claude Design also closes by 2026-12-14.

## Intent

Flosis makes the designs itself, inside the Workshop pipeline.

- **Setup.** When a project switches Designs on, a setup run recreates the
  client's current app as a design system, components and clickable screens.
  These become the design repo's `master`.
- **Per task.** Claude — driven by Flosis's own prompts, skills and style packs
  — builds clickable, browser-runnable prototypes of the change on a working
  branch of the project's **design repo**. The user steers it in a chat next to
  a live preview and approves.
- **After approval.** The approved version becomes the task's design branch and
  is merged into `master`. The Jira task gets links that open it in the right
  context, and from there anyone can click through the app.

A developer — or the developer's own AI — then starts from the Jira task with
everything in place: the description with the product answers, and finished
designs built from the project's components. Only technical decisions are left,
and once implemented the task is ready for testing and the rest of the process.

Why this matters:

- A complete task removes the back-and-forth between product and development.
- Designs are versioned files in git, so there is no snapshot to go stale and
  nothing to drift.
- How the designs get made — prompts, skills, style packs — is Flosis's
  intellectual property and the product's edge. It never leaves Flosis's
  servers.

## Goals

1. **A separate Designs module** inside Workshop. It is enabled per project and
   developed on its own (own models, controllers, views, jobs and services). It
   touches the existing pipeline only at the integration points this document
   names.
2. **A design repo per project on GitHub** holding only outputs: the design
   system, components, designs, the files needed to open them in a browser, and
   a README for developers.
3. **A setup run** that recreates the existing app — design system, then
   components, then the current screens — from the app's code, a crawl of the
   running app with login credentials, and optional Figma or other materials.
4. **A Designs screen**: chat on the left; preview and context picker on the
   right; the approved top bar.
5. **Two ways in and both directions**: designs can come first and produce the
   description, or the description can come first and produce the designs, and
   the user can move between them at any time.
6. **A working branch per task.** The user approves, the task's design branch
   moves to the approved version, and it is merged into `master`. Jira links and
   the developer's branch always show the last approved version.
7. **Contexts**: modifiers such as a user's permissions or their organization's
   plan. Claude creates them when the user asks; they are picked next to the
   preview and carried in links.
8. **Links in Jira** that open the task's approved prototype in a given
   context.
9. **A configurator** for each project's design settings, and a Flosis-wide
   library of prompts, skills and style packs that only the Flosis team can
   open.
10. **A developer path** that needs no Flosis access: the developer's AI finds
    the design branch from the Jira key by convention and reads the design repo.

## Non-goals (this version)

- No canvas, artboards, inline comments, tweak knobs or visual editing. Chat and
  preview only.
- No backend in prototypes. Fake data only.
- No changes to the client's application repository. Implementing stays with
  the developer.
- No Figma export. The existing "Request from designer" flow stays as it is.
  Figma is only an optional input to the setup run.
- No automated comparison of implemented screens against the approved designs
  (a natural follow-up, not now).
- No activation flow or billing for the setup run. It will be charged
  separately later.
- No premium dedicated-server deployment work. Nothing may assume a single
  shared server, though: domains, paths and credentials stay configurable.

## Anti-goals (a failure even if everything else works)

- Flosis prompts, skills or style packs ending up in a client's GitHub, in a
  client checkout, or on any screen a client user can open.
- Prototypes styled ad hoc instead of from the project's design system and
  components.
- A link in Jira, or the branch a developer checks out, showing anything other
  than the last approved design for that task.
- Client design work running on a personal or consumer Claude subscription
  logged in on the server. Licensing forbids routing requests through consumer
  subscriptions from 2026-11-12.
- AI-generated HTML or JavaScript executing on the `app.flosis.com` origin.
- Client app login credentials ending up in the design repo, a chat transcript
  or a prompt the client can see.

## Decided by Kacper

1. Designs is part of Flosis (this repo, the Workshop product) but a separate
   module: added to a project, developed on its own, with its own scheme,
   process and configurator.
2. Three layers: a **design system** (brand, tokens, assets), **reusable
   components** with documentation, and **clickable designs**. Inspirations are
   kept separate from the design system.
3. Only `design_system/`, `components/`, `designs/` and the files needed to open
   them in a browser are pushed to GitHub.
4. Two ways in:
   - **A — designs first.** Start in Designs. Then move to Details gathering,
     where Claude writes the task description from the designs on the client's
     behalf and challenges missing requirements.
   - **B — brief first.** Briefing → Details gathering, and at any moment jump
     to Designs with the current description; Claude starts designing the
     changes straight away.
5. Claude creates a branch per task and works on it. When the user approves,
   the work lands on `master`.
6. Tasks live in Jira. Once a design is ready, its links are added to the task
   separately. Clicking one opens the prototype, and you can click on through
   the app.
7. Contexts are modifiers used by the designs, such as the user's permissions
   or their organization. Claude creates them from the Designs screen when the
   user asks. They are picked on the right, next to the preview.
8. The developer starts from the task. Their own AI reads the task description,
   has access to the design repo, and knows the branch by convention, so it can
   implement from the developer's machine.
9. The UI is only a chat and the design preview, beside the chat or in a new
   tab. The top bar from the first mockup is approved as is: breadcrumb
   (`Workshop › <KEY> <title> › Designs`), branch pill with commit count, "Open
   in new tab ↗", "Approve → master".
10. Prompts, skills and style packs are configurable in the configurator.
11. Prompting and style tooling are Flosis's intellectual property and must not
    be inside a client's GitHub.
12. Today all of Flosis runs on one server. Later there will be one shared
    instance plus a premium tier where Flosis runs on a dedicated server for a
    client: a closed ecosystem where the client never sees Flosis code.
13. **The first `master` comes from a setup run.**
    - Inputs: the app's code, credentials, and optionally Figma or other
      materials.
    - It recreates the current app in order — design system, then components,
      then designs (the current look) — using a crawler, the repo and the
      credentials.
    - A Flosis team admin usually runs it, when a client asks for the feature to
      be activated. It runs on Flosis's own separate account and will be
      charged separately; billing does not matter at this stage.
14. **When an approved task is reopened**, the Jira links and the developer's
    branch keep showing the last approved version until the next approval.
15. **The pilot is Flosis (Gold) itself.** No deadline was set.

## Current state (verified 2026-10-30)

What the module plugs into, and the traps it must not repeat:

- **Ideas are `Task` rows** with `workshop_stage` (`new`, `briefing`, `details`,
  `ready`; `task.rb:69`). The stage names are listed in about ten places
  (`ideas_controller.rb`, `_stepper.html.erb`, pipeline views,
  `Workshop::BaseController::STAGE_ORDER_SQL`, …).
- **Documents are versioned.** Briefing produces `Brief` rows and Details
  produces `TaskDraft` rows (source `"ai"`), both through `VersionableDocument`
  (`current` flag, `origin`, `make_current!`). The AI's output is pulled from
  strict tagged blocks (`<brief>`, `<draft>`), and each block becomes a new
  version.
- **Chats run inside the web request**, streamed as SSE (`ChatStreaming`,
  `ActionController::Live`). One `ChatSession` per task and purpose. Puma has 3
  threads, so each running chat holds one for the whole CLI run.
- **Chats are hard-wired to Elvium.** They always run Claude in `~/work/elvium`
  (or `CHAT_CODEBASE_PATH`), their prompts say "the Elvium HR app", and they
  only work for Jira-connected projects. The AI jobs, by contrast, use
  per-project folders under `CLIENTS_BASE_DIR/<ws>/<project>/`.
  `ProjectRepoCheckoutJob` exists but is never enqueued, and it stores the
  GitHub token in `.git/config`.
- **Gold is not a Workshop project today.** Only Elvium has a board, a
  repository or tickets (`projects.show_in_workshop`, commit 4e281d8). Gold's
  UI is Tailwind v4 through `tailwindcss-rails`, with its own tokens in
  `app/assets/tailwind/application.css` (`@theme`) and `clar-` classes in
  Workshop.
- **`ClaudeCliService`** runs `claude -p` with an allowed-tools list. No list
  includes Write, Edit or Bash. There are no timeouts and no
  `--append-system-prompt`, and the CLI inherits the whole Rails environment.
  `projects.anthropic_api_key` exists (encrypted) and
  `ProjectCredentials#anthropic_api_key` resolves it, but nothing passes it to
  the CLI.
- **No git writes anywhere.** Nothing creates branches, commits or pushes.
  `GithubClient` can read PRs and post reviews, nothing more.
- **Design links today:** one `DesignRequest` per task, and
  `JiraWriter#sync_design_links` rewrites a `--- Designs ---` block at the end
  of `tasks.description`. That block is fragile:
  - Jira sync overwrites `tasks.description` every 15 minutes.
  - Later description pushes drop the block.
  - The ADF round trip can break the pattern and duplicate it.
- **All Jira writes use the global `.env` Jira credentials** (`JiraClient.new`),
  not the project's.
- **Configuration** has the tabs integrations, ai, briefing and users. Tabs are
  gated per project by `configuration` or `briefing_config`, and locked (not
  hidden) when the user lacks the permission. Workspace admins hold every
  permission.
  - There is **no platform-level admin**. Anyone can self-register a workspace
    and become its admin.
- **Prompts** are heredocs in code, plus a few database fields
  (`pr_review_prompt`, `alert_rules.prompt` with version history,
  `briefing_personas`).
- **Hosting and capacity:**
  - Nothing serves static files per project.
  - Production is Hostido shared hosting. Every hostname is its own document
    root with its own `.htaccess`, TLS is managed in the panel, and `/tmp` is
    noexec. There is no Docker.
  - `*.flosis.com` hosts land in Workshop routing.
  - Solid Queue runs 1 process × 3 threads, and every job uses `:default`.
  - Workshop has no Turbo Stream broadcasts (solid_cable is configured but
    unused).
  - A deploy restarts Solid Queue and kills any running job.
- **Rules from earlier specs that still apply:**
  - The app holds the source of truth.
  - Every Jira write returns `{ok:, error:}`. On failure, keep the local state
    and show the error; never flip a status silently.
  - Permissions go through `ProjectAccess` and the wording through
    `PermissionPreset::LABELS`.
  - Credentials resolve only through `ProjectCredentials`.
  - Migrations must be MySQL-safe and re-runnable. Dev and test run Postgres;
    production runs MariaDB.
  - HR files stay untouched.

## How it works

### The pieces

| Piece | Lives in | Holds |
|---|---|---|
| Design repo | GitHub, one per project | Outputs only: design system, components, designs, runtime, README |
| Designs module | This repo (Workshop) | Setup run, Designs screen, configurator tab, turn runner, git and publish services, Jira links |
| Flosis library | Flosis database | Prompts, skills, style packs — the intellectual property; never written into a design repo |
| Preview host | A separate domain on the Flosis server | Published branches, served as static files |

### The design repo

```
README.md        conventions for developers and their AI (generated by Flosis from a non-IP template)
index.html       entry point: links to the design system, components and screens
design_system/   brand book (README), tokens, assets, fonts
components/      one folder per component: guidelines, a preview, the component itself
designs/         clickable screens of the app, their fake data, and the contexts definition
runtime/         what the browser needs: base-kit CSS, the context runtime, the component loader
```

Rules:

- **No build step for anyone viewing it.** It opens from any static file server
  (for example `ruby -run -e httpd .`). Opening via `file://` is not required.
  Third-party assets are vendored and pinned, with no CDN at view time.
- **Utility-CSS kits.** For a kit that has to be compiled, such as the pilot's
  Tailwind v4, the compiled CSS is produced by Flosis when it commits, or by an
  in-browser compiler vendored into `runtime/`. Which one is the builder's call.
- **Components are single-source.** A screen reuses a component and never
  copies its markup. The mechanism (HTML partials pulled by a small loader,
  custom elements, …) is the builder's call.
- **Stack-neutral HTML, CSS and JS** that a developer or an AI can port to ERB,
  React or anything else. The project's **base kit** (for the pilot, Tailwind
  v4 with Gold's own tokens) is chosen in the configurator and decides what goes
  into `runtime/`.
- **Fake data** sits beside the screens and varies by context.
- **Contexts** are defined in the repo, so they version and merge with the
  designs:
  - They are grouped into dimensions, for example *Permissions* (workspace
    admin / project manager / client) and *Product* (Time & HR / Workshop).
  - One value per dimension is active. The active combination lives in the URL
    (`?ctx=admin,workshop`) and survives navigation between screens.
  - Screens show, hide or vary elements by context.
- **Leak guard.** Before every commit, Flosis refuses the commit if it touches
  paths outside the six above. It also refuses a diff that contains verbatim
  passages from the Flosis library or any stored credential.

### Branches

| Branch | Holds | Who moves it |
|---|---|---|
| `master` | All approved designs: the target look of the app. It may be ahead of what is deployed. | Approvals (merge commits) |
| `design/<KEY>` | The task's last approved version. The developer convention points here; Jira links show it. | Approval only |
| `wip/<KEY>` | The task's work in progress. The Designs preview shows it. | Every Claude turn (one commit per turn that changes files) |
| `wip/setup` | The setup run's work in progress | Setup turns |

- **Before the Jira issue exists**, the names use `task-<task id>` instead of the
  key and are renamed when the issue is created. Working branches must not be
  nested under `design/<KEY>/`, because git cannot hold a branch and a folder of
  the same name.
- **Approve → master:**
  1. Point `design/<KEY>` at the head of `wip/<KEY>`.
  2. Merge it into `master` with a merge commit.
  3. Push both and publish both.
- **Conflicts.** If the merge conflicts because `master` moved, Flosis says so.
  The user asks Claude, in an ordinary turn, to bring `wip/<KEY>` up to date
  with `master`, then approves again.
- **Reopening** an approved task continues on `wip/<KEY>`. `design/<KEY>` and
  the Jira links stay on the last approved version until the next approval
  (decision 14).
- Branches are never deleted, so the convention keeps working after the merge.

### The setup run (bootstrap)

- **Who and when.** Only the Flosis team starts it, from the project's Designs
  configuration, typically when a client asks to have Designs activated. It can
  be run again later to refresh `master`; a re-run is reviewed and approved
  like any other change.
- **Inputs:**
  - the app repo, as a read-only checkout;
  - the running app's URL, with login credentials for each role worth
    capturing;
  - optionally Figma files (through the existing Figma integration) and other
    materials (uploads).
- **Phases, in order, in the same chat and preview screen at project level, on
  `wip/setup`:**
  1. **Design system** — tokens, typography and assets, taken from the code and
     checked against the crawl.
  2. **Components** — the app's real UI building blocks, from its views,
     partials and components, checked against the crawl.
  3. **Designs** — the current screens recreated as clickable pages with fake
     data. The roles the crawler logged in as become the first contexts.
- **Review.** The Flosis team reviews each phase in the chat. Approval merges
  `wip/setup` into `master`.
- **Crawling.** A headless browser, logged in with the stored credentials,
  collects pages, the DOM and screenshots per role.
  - Whether Claude drives it (for example through a Playwright MCP server) or a
    crawl step runs first and hands its results to Claude is the builder's
    call.
  - Credentials never reach the repo, the chat or a client-visible prompt.
- **Account.** It runs on Flosis's own API key (a Flosis-level setting, not the
  project's key, and never a consumer subscription login).
- **Configurator inputs are the starting point, not the source of truth.**
  After setup, the design repo is the source of truth. Brand inputs, base kit
  and style pack feed the setup run and later turns as context, but they never
  regenerate files on their own. Later design-system and component changes ride
  on task branches, or on a new setup run.

### The Designs screen

- **Top bar** as approved:
  - the breadcrumb;
  - the branch pill: the task's design branch name and the number of commits
    waiting for approval;
  - "Open in new tab ↗": the work-in-progress preview with the current
    contexts;
  - "Approve → master".
- **Left — chat** with Claude, one history per task. Besides ordinary replies,
  Claude's messages can be:
  - a turn summary of what changed;
  - a "new context" notice;
  - a "missing requirement" question. These questions are carried into Details.
- **Right — preview**: the work-in-progress branch on the preview host, in an
  iframe. Above it is the context picker, one row per dimension. Adding a
  context is not a form: a hint invites the user to ask Claude in the chat.
- **Setup** uses the same screen at project level, reached from the
  configuration, with a phase indicator in place of the task breadcrumb.
- Mockup: `.superpowers/brainstorm/52989-1793381523/content/designs-screen-v2.html`
  (local only, git-ignored).

### Moving between Briefing, Details and Designs

- **Designs is a screen, not a stage.** `workshop_stage` and its call sites stay
  as they are. The idea page gets a "Designs" entry next to the stepper, usable
  at any stage.
- **Path A.** The pipeline's "New idea" gains "Start with designs". It creates
  the idea and opens Designs. "Continue to Details" sets the stage to `details`
  without going through Briefing. Claude then writes a new `TaskDraft` version
  from the designs plus whatever brief exists, ending with an *Open questions*
  list that includes the "missing requirement" questions raised in the chat.
  The Details chat continues from there and challenges what is missing.
- **Path B.** From Briefing or Details, "Designs" opens the screen. The current
  description is the current `TaskDraft` if there is one, else the current
  `Brief`, else `tasks.description`. Claude designs from it straight away.
- When the designs change after a Details draft exists, Designs offers to
  update the draft as a new version. It never updates it silently.

### Claude turns (the runner)

- **Every chat message is one background job**, not an SSE request. Turns take
  minutes and Puma has 3 threads. Only one turn runs per task at a time. The
  chat shows that Claude is working and updates when the turn ends; the
  mechanism (Turbo Streams over solid_cable, or polling) is the builder's call.
  Design turns must not starve the other jobs: they get their own queue or
  worker.
- **A turn:**
  1. Make sure the project's design repo checkout exists, with a worktree for
     the working branch, under the project's folder in `CLIENTS_BASE_DIR`.
     When the project has an app repo, also give Claude a read-only checkout of
     it so designs stay true to the real app.
  2. Render the library pieces this turn needs (prompt, skills, the project's
     style pack) into a temporary directory **outside** the worktree.
  3. Run Claude with the worktree as working directory: read and edit file
     tools only (no Bash, no git, no web), the library content appended to the
     system prompt, and a timeout.
  4. Flosis — not Claude — runs the leak guard, commits, pushes and publishes.
- **Failure handling.** If a turn crashes, times out or is killed by a deploy,
  uncommitted changes are discarded and the turn is marked failed with a retry.
  The branch always sits at the last good commit.
- **API keys:**
  - Task turns run with the key stored on the project. For Flosis's own
    projects that is the company key, entered there.
  - There is no fallback to an environment key or to the server's OAuth login.
    Designs refuses to start for a project without a key.
  - The setup run uses Flosis's own key.
  - `ClaudeCliService` cannot pass a key today, so that wiring comes first.
- **Git authentication.** The design repo has its own token with write access
  to that repo only, kept separate from the project's read-only app-repo token.
  It is never persisted into `.git/config`.

### The configurator and the library

- **Per project** — a new "Designs" tab in Workshop › Configuration, gated by
  `configuration`:
  - Designs on/off;
  - design repo (`owner/name`) and its token;
  - base kit;
  - style pack, picked by name;
  - brand inputs (logo, colors, fonts);
  - inspirations (uploads, kept in Flosis and never pushed).
- **Setup inputs** — app URL, credentials per role (encrypted), optional Figma
  and materials — and the "Start setup" action are visible only to the Flosis
  team.
- **The Flosis library** — prompts, skills, style packs:
  - It is one library for all of Flosis, in a staff-only area outside
    workspace scoping.
  - Access comes from a new **Flosis staff** flag on users. It is not a
    workspace role, and self-registered workspace admins never get it.
  - Projects pick a style pack and supply their own inputs; they cannot read or
    override library content.
  - The library is versioned. Flosis records which library version produced
    each commit in its own database, not in the repo.
- **A style pack is guidance**: prompts, rules, examples, anti-patterns and a
  review checklist for one visual style. It stays in Flosis. What Claude
  produces with it (tokens, CSS, components) is the client's output and is meant
  to ship; the leak guard only blocks verbatim library text.
- **The first style pack is drafted for the pilot** with Kacper's direction.
  Earlier feedback points to a calm, Apple-like style.
- Using the Designs screen and approving need `tasks`, like the rest of the
  idea page.

### The preview host

- **A separate registrable domain**, not a `flosis.com` subdomain:
  - A `flosis.com` subdomain would land in Workshop routing.
  - It would also share the same site as the app.
  - The domain name is Kacper's choice.
- Apache serves it as static files from its own document root, under a long,
  random, revocable token per project.
- **Approved versions.** On approval Flosis publishes `design/<KEY>` to
  `<docroot>/<project token>/<KEY>/`, and `master` to
  `<docroot>/<project token>/master/`. Jira links point there:
  `https://<preview domain>/<project token>/<KEY>/<screen>?ctx=…`.
  - Anyone with a link can open it, which matches "click it in Jira and keep
    clicking".
  - Rotating the token revokes every link of the project.
- **Work in progress** is published after every commit to a separate path that
  Jira never links. Only the Designs screen uses it.
- **A task's link always shows the task's last approved version.** Work in
  progress and later changes to `master` never change it.

### Jira links

- **On approval** (and on every re-approval) Flosis writes the links to the
  Jira issue as remote links ("Web links"). The description is not touched,
  because sync and later pushes overwrite it.
  - It writes one link per screen × context listed in a per-task manifest that
    Claude keeps in the repo, plus one link to the task's index page.
  - It uses the **project's** Jira credentials.
  - It follows the Jira write rule: `{ok:, error:}`, local state kept on
    failure.
- **No Jira issue yet:** the links are written when the issue is created.
- **Projects without Jira** show the links in Flosis only.

### The developer path

- The design repo's README states the convention:
  - `design/<KEY>` is the task's approved design;
  - where screens and components live;
  - how contexts work;
  - how to run it locally;
  - how to see what the task changed, in a form that still works after the
    merge (the exact command is the builder's call).
- The developer's AI:
  1. reads the Jira issue (description and Web links);
  2. checks out `design/<KEY>`;
  3. implements in the application repository.

## The pilot: Flosis (Gold)

Gold becomes a Workshop project: `show_in_workshop`, its GitHub repo, and its
Jira project if it has one. Without Jira, the links show in Flosis only and
tests cover the Jira path.

Choosing Gold adds these prerequisites:

1. **Project-aware chats.** The Briefing and Details chats must run in the
   project's own checkout, name the project instead of "the Elvium HR app", and
   work without Jira. Paths A and B hand over to these chats, and today they
   point at Elvium.
2. **API key wiring.** `ClaudeCliService` passes the project's key, as
   described above.
3. **Working checkouts.** `ProjectRepoCheckoutJob` is actually enqueued, and
   the token stays out of `.git/config`.
4. **Tailwind v4 runtime CSS** for prototypes, with Gold's tokens, and no
   build step for anyone viewing it.
5. **A first style pack.**

## Risks to verify first

- **A headless browser on Hostido shared hosting** (noexec `/tmp`, no Docker)
  is unverified. Check it before building the crawler. The fallback is to run
  the crawl on another machine, for example a Flosis team machine, and upload
  its results.
- **Capacity.** Solid Queue has 3 threads in total, and a design turn can take
  minutes. Design turns need their own queue or worker, sized so that
  automations and PR reviews keep running.
- **The preview domain** needs registering and TLS through the Hostido panel.

## Claude's calls (please check)

1. Designs is a screen reachable at any stage, not a new `workshop_stage`.
2. Branches are `wip/<KEY>` (work in progress) and `design/<KEY>` (approved),
   plus `wip/setup`. Before the issue exists they use `task-<id>` and are
   renamed. Merges are merge commits, branches are never deleted, and a
   conflict is resolved in an ordinary turn.
3. Jira links are remote links ("Web links") written on approval, not a block
   in the description.
4. The preview host is a separate domain serving static files, with capability
   URLs behind a revocable per-project token. Approved versions and work in
   progress have separate paths.
5. The current description is the current `TaskDraft`, else the current
   `Brief`, else `tasks.description`.
6. Inspirations are stored in Flosis, not in the design repo.
7. Contexts are grouped in dimensions, with one value per dimension and the
   combination in the URL. They are defined in the repo, created on the task
   branch, and available to every task after the merge. The setup run seeds
   them from the crawled roles.
8. Turns run as background jobs, one at a time per task. Flosis does every git
   operation, behind the leak guard.
9. The design repo has its own write token, separate from the app repo's.
10. "Request from designer" stays untouched and coexists.
11. Using Designs needs `tasks`; the Designs tab needs `configuration`.
12. The library is Flosis-wide and staff-only (new Flosis staff flag), with no
    per-project overrides. It is versioned, with the commit → version mapping
    kept in Flosis.
13. The API key is required on the project, with no environment fallback. The
    setup run uses Flosis's own key.
14. A style pack is guidance that stays in Flosis; what is produced with it
    ships.
15. After setup the design repo is the source of truth, and configurator inputs
    never regenerate files.
16. Task turns get a read-only checkout of the app repo when one exists.
17. The setup run is a project-level session on the same screen, with three
    phases and staff approval, and it can be re-run.

## Left to the builder

- Exact file formats: tokens, component docs, the contexts file, the per-task
  manifest.
- The component reuse mechanism, the context runtime, and how the Tailwind CSS
  is produced.
- The crawler mechanism, within the credential rules above.
- The live-update mechanism, the job queue setup, timeouts.
- Checkout and worktree management, how publishing copies files, and the "what
  did this task change" command in the README.
- The data model: new tables, or `ChatSession` with a `designs` purpose.
- The runner's exact tool list and the wording of prompts and skills.
- UI details beyond the approved top bar and the chat / preview / context
  layout.

## Testing

- Minitest with fixtures. `ClaudeCliService`, git, publishing and the crawler
  are stubbed with `define_method` and restored in `ensure`, as the existing
  tests do. WebMock covers Jira and GitHub.
- Unit tests:
  - the leak guard (paths, verbatim library text, credentials);
  - branch naming, the rename, and approval moving `design/<KEY>`;
  - resolving the current description;
  - building context URLs;
  - the Jira remote-link writer, including failure handling;
  - the Flosis staff gate.
- Integration tests:
  - the Designs screen;
  - the configurator tab, its permission gate, and the staff-only setup inputs;
  - "Start with designs";
  - "Continue to Details";
  - approval and reopening, including the check that Jira links keep the
    approved version.
