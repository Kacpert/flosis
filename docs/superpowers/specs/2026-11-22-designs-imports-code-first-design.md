# Designs imports: Stop, a form before New import, and code-first imports with feedback

Kacper, 2026-11-22 (02:40–03:20). He started a New import ("Changes since
Nov 10", import 3) and had to ask for it to be stopped and deleted by hand:
there is no Stop, and New import started at once, before he could change the
links or add a context. Then he asked for imports to work from the code first.

## Intent

Imports bring what developers built into the designs. The app's repository
holds every front-end change, so the import should start from the code: from
the commit where the last import left off, with git, reading as much of the
history as it needs. It imports what it can, also for a role it cannot sign in
as (from the code, without opening the page), and when it needs something from
the person, or sees more than it was asked for (a role the setup lacks, a
login that failed), it says so at the end: "an extra step that usually does
not happen". The person can then add what it asked for and import more.

Why now: import 3 found 3 features to update since Nov 10, while the app's diff
since then is about 1.2 MB in 261 files. Designs::AppChanges cuts a diff at
400 KB, so the AI saw about a third of it: it stopped in
`app/views/workshop/consumption/` and never saw `config/routes.rb` or the
designs and ideas views.

## His decisions (2026-11-22)

1. **Stop** on a running import.
2. **New import opens a form** first (the links, the app repositories, the
   contexts and their logins, a new context), and starts on its button.
3. **Code first, with git.** "It should simply have git and a local copy of the
   project: that way it has everything." The import remembers the commit it
   read; the next one reads the history from there.
4. **Routes in any framework.** The import reads the app's paths whatever the
   framework calls them (routes.rb, a pages folder, a router config, urls.py).
5. **Interaction: the import runs to the end and imports what it can.** When it
   sees more, or needs something from the person (a role it did not have), it
   gives that feedback at the end. Usually there is none.
6. **Import more after it is done.**
7. Ship everything tonight; he tests in the morning.

## Goals

- Stop a running import (or the queue of a finished one) at once, from its page.
- Delete an import that stopped or failed before anything of it reached master.
- New import opens the setup form, filled in, and starts from it.
- Every import turn can read the app's git history, read-only, without limit
  of size: no truncated diff.
- A resync finds what changed from the code alone: git history since the last
  import, the routes, the roles. No browser in that step.
- A context without a login, or one whose sign-in fails, is built from the
  code, marked as such; the import never stops because nobody can sign in.
- Turns leave suggestions for the person; the import page shows them at the
  end as Feedback, with actions that import more.

## Non-goals

- A chat with the import (variant c) or a review step before building (a).
- Storing a list of routes between imports: git shows what changed in them.
- A shell for Claude. Turns stay `--restricted`.
- Changing how features are built in the browser, how they land on master, or
  the re-import on a thread.
- Deleting an import whose work reached master.

## Anti-goals

- Claude reaching anything but the project's own clones (the host is shared
  with client WordPress sites; a shell or a writable git could read other
  clients' files or Flosis's secrets).
- Passwords anywhere but the form and the sign-in script's stdin.
- Feedback that cries wolf: a card only for something the person can act on
  or should know.
- An import that silently does less: what was built from the code says so.

## Constraints

- Production is MariaDB; JSON columns need `attribute :x, :json`.
- The node tools (lib/designs_crawler/*.mjs) run from `shared/designs_crawler`
  on the server; `cap deploy` does not update them: the deploy uploads them.
- Hostido drops SSH after 3–4 quick connections: server work rides the
  deploy's connection.
- A deploy restarts Solid Queue; deploy with no import running.
- The setup prompts for map, design system and feature live in the Library on
  production (staff can edit them); the resync prompt is only in code.
  Instructions that must reach production go in code: the resync prompt, the
  turn message and the system notes of Designs::Subject::SetupSubject.
- Tests: Minitest, `PARALLEL_WORKERS=1`; node tests for the .mjs tools.

## Approaches considered

How Claude reads the history:

1. **A read-only git tool** (chosen). A new MCP server, `flosis_git`
   (lib/designs_crawler/git.mjs), runs allowlisted, read-only git commands on
   the project's own bare clones, with a sanitized environment and a cap per
   call. Claude asks for exactly the log, diff, show or blame it needs.
2. A shell with git. Simplest, but a shell on the shared host reaches other
   clients' files and the app's secrets; turns are `--restricted` for that
   reason. Ruled out.
3. Pre-computed diffs, split per file instead of one cut file. Safe, but the
   AI cannot follow a change through history (log, blame, show), and huge
   diffs still need limits. Weaker than 1 for the same work.

How the person is asked (his choice, variant b): the import runs to the end;
suggestions gather as cards; acting on one queues more work on the same
import. A plan-first review step (a) and a chat (c) were not chosen.

## Design

### 1. Stop

- `post :stop` on an import (`Workshop::DesignImportsController#stop`), for
  people with the configuration permission, while the import is busy.
- `Designs::ImportStop.new(setup, user).stop!`:
  - A running import (active, not finished): status `failed`, `stopped_at`,
    `stopped_by` (new columns), error nil, unit claim cleared, `paused_until`
    cleared.
  - A finished import with features queued or running (follow-up work): those
    features become `failed`, error "Stopped by <name>.", finished now. The
    import stays approved.
  - Every active setup turn of the import (sessions with its
    `design_setup_id`): its Claude is killed (Designs::SetupRunJob.killer, by
    session id; the browser and git servers exit when Claude's stdin closes)
    and the turn fails with "Stopped by <name>.".
- Designs::SetupRunJob respects a stop: `stop` and `pause` leave a stopped
  import as it is (they do not overwrite it); nothing new is enqueued. A
  non-Claude step under way (a clone, a sign-in) ends by itself, and the job
  then finds the import over.
- **Resume** is the existing Retry: it also clears `stopped_at`/`stopped_by`,
  and puts back to `todo` the features that failed at or after `stopped_at`,
  so the import goes on with the feature it was building.
- The page: a "Stop" button beside the title while the import is busy (with a
  confirm: "Stop this import? What is on master stays; you can resume it.").
  A stopped import's card reads "Stopped" / "Stopped by Kacper at 02:47. What
  is on master stays." with Resume and, when allowed, Delete. The list entry
  says "Stopped" instead of "Running in the background".

### 2. Delete

- `delete :destroy` on an import. Allowed for a resync (kind `resync`) that is
  failed or stopped, not busy, with no feature `done` (nothing of it on
  master). Otherwise refused with a toast.
- `Designs::ImportDeletion.new(setup).delete!` removes, in order: the branches
  of its features (`wip/import-<id>-<key>`, each worktree, local branch and
  GitHub branch, through Designs::Repo), its chat sessions (`designs_setup`
  sessions with its id: turns and messages go with them), the import (features
  and views go with it), and its run folder (`design-runs/<id>`).
- A Delete button (with a confirm) on the stopped or failed card; after it,
  the imports list with "Import deleted".

### 3. New import opens the form

- "New import" links to `GET /workshop/designs/imports/new`, which renders the
  setup form (workshop/design_setup_runs/new) in import mode: title "New
  import", a line "What developers built since <date>", the app repositories
  and the contexts editable (add, change, remove; passwords kept when left
  blank), the stack and the designs repository shown read-only, and a "Start
  import" button posting to `create`.
- The form's saving moves from DesignSetupRunsController into a service
  (`Designs::SetupForm`), used by both controllers, so validation and messages
  stay one.
- `create` saves the form, then does what it does today (refused while another
  import works, or before master has the first one) and starts the resync.
- A context can be added without a login: "No login · build from the code"
  (see 5).

### 4. Code first, with git

- **History clones.** `Designs::AppHistory.new(project)` keeps a bare, full
  clone of each app repository of the setup in the project's folder
  (`<designs_dir>/app-history/<n>-<repo>.git`, folders 0700), made on first use
  and fetched at the start of every import (read_repos) and before a
  follow-up feature. Fetching uses the project's GitHub token through
  GitRunner, as AppRepos and AppChanges do. Full clones: the git tool never
  needs the network or a token.
- **What changed.** Designs::AppChanges reads `from` (the commit the import it
  starts from recorded, as today, else the branch's commit when that import
  started) and `to` (the branch head now) from the history clone, records
  `to` in `app_commits`, and returns per repository: repo, branch, from, to,
  the number of commits, and a `git diff --stat` summary (bounded). It no
  longer writes cut diff files.
- **The git tool** (`flosis_git`, tool `git`): input `{ repo, args }`; repo is
  one of the setup's repositories as `owner/name`. It runs
  `git --no-pager -c core.hooksPath=/dev/null -c protocol.allow=never
  --git-dir <clone> <subcommand> <args>`:
  - subcommands allowed: log, show, diff, blame, grep, ls-tree, rev-parse,
    rev-list, shortlog, cat-file, merge-base, diff-tree, for-each-ref,
    describe, name-rev;
  - refused options: anything that writes or reads a file outside the
    repository or runs a program: `--output`, `--ext-diff`, `--textconv`,
    `--filters`, `--no-index`, `--contents`, `--ignore-revs-file`, `-O`,
    `--open-files-in-pager`, grep's `-f`/`--file`, blame's `-S`, `--exec`,
    `--upload-pack`, `-c`, `--config-env`, `--git-dir`, `--work-tree`,
    `--namespace`, `-C`;
  - diff, show and log get `--no-ext-diff --no-textconv`; grep gets
    `--no-textconv`;
  - environment: only PATH, plus `GIT_CONFIG_NOSYSTEM=1`,
    `GIT_CONFIG_GLOBAL=/dev/null`, `HOME` an empty folder, `GIT_PAGER=cat`,
    `GIT_TERMINAL_PROMPT=0`, `GIT_ATTR_NOSYSTEM=1`, `GIT_NO_REPLACE_OBJECTS=1`;
  - output capped at 100 KB a call, past which it is cut with "(cut at 100 KB:
    narrow it with a path, a range or --stat)"; 30 s timeout;
  - the clones it may use come from `FLOSIS_GIT_REPOS` (JSON, owner/name →
    path).
- Every setup turn (map, design system, feature, resync) gets the git tool
  when the project has history clones; the system text says what it is for.
- **The resync's look at what changed is code-only.** No sign-in, no browser
  tools: Claude reads the history (from..to per repository, given in the
  message with the summary), the routes in whatever form the framework has
  them, the navigation, and the roles and permissions. It saves features as
  today, and leaves suggestions (6). Its flosis_browser server still runs, for
  save_features and suggest; the browser starts only when a browser tool is
  used, and none is allowed.
- The first import's map turn and the feature turns keep their browser and
  gain the git tool; their prompts are in the Library, so what they need to
  know about git, code-only contexts and suggestions comes in the
  SetupSubject's system notes and turn message, which are code.

### 5. Contexts built from the code

- A context can be **code-only**: `design_setup_roles.code_only` (boolean,
  default false). A code-only context needs only its name: no URL, login or
  password; it is never signed in.
- Designs::SignIn signs in the contexts that have a login. One that fails is a
  note on the run (as today) and a suggestion (`sign_in`). When none can sign
  in, the run no longer stops: it goes on, every context from the code, with
  the note and the suggestion.
- The turn message's Contexts list says, per context, whether it has a
  browser (signed in now) or is built from the code, and why (no login; the
  sign-in failed). A system note tells the turn how: a context without a
  browser is built from its routes, permissions, views and components, with
  fake data of the kind its views show, and its screens are said, in a
  `<missing>` note, to be built from the code and not checked against the app.
- A feature records the contexts it was built from the code for
  (`design_setup_features.from_code`, JSON array of slugs), set when its turn
  starts. The import page shows "From code: <names>" on it.

### 6. Feedback: suggestions at the end, and importing more

- **Model:** `DesignImportSuggestion` (`design_import_suggestions`): import,
  kind (`context` | `sign_in` | `other`), key (for dedupe, unique per
  import), title, detail, context_name, role (for `sign_in`), features (JSON:
  map keys the AI named), status (`open` | `done` | `dismissed`), acted_by,
  acted_at.
- **Sources:**
  - a `suggest` tool on flosis_browser (every setup turn but a check), input
    `{ kind: "context" | "other", title, detail, context?, features? }`,
    appended as JSON lines to `run_dir/suggestions.jsonl`; after each turn the
    job reads the file into suggestions (deduped by kind and normalized
    context or title) and empties it;
  - Designs::SignIn: a context that could not sign in (`sign_in`, keyed by the
    role);
  - Designs::AppRepos: a repository that could not be read (`other`).
- **The import page:** a "FEEDBACK · n" section, shown when the import is not
  running and has open suggestions, above Built. Each card has its title, its
  detail and its actions:
  - `context` (a role the setup lacks): **Add login** (an inline form: login
    URL, login, password) and **Build from code**: either adds the context to
    the setup (with its login, or code-only) and queues its screens; and
    **Dismiss**.
  - `sign_in` (a context that could not sign in): **Fix login** (inline form,
    URL and login filled in, password blank): saves it and queues that
    context's screens again, to be checked against the app; **Dismiss**.
  - `other`: **Dismiss**.
- **Importing more** (queued on the same import, as Missing feature? · Add
  does): for a context, one follow-up feature per feature of the map the
  suggestion names ("<feature> · as <context>", contexts = that context, the
  map feature's brief and screens, plus "Build only what <context> sees"); none
  named: one feature "<context>'s screens" whose brief is the suggestion's
  detail. Then `start_work!`. The import is busy again, and Stop applies.
- The imports list shows "n suggestions" on an import that has open ones.

## What's left to the builder

- Exact copy beyond what is quoted here, in the Workshop's voice (short,
  plain, English).
- The layout of the Stop button, the stopped card, the Feedback cards and the
  import-mode form, in the style of the import page and setup form.
- How the deploy uploads the .mjs tools (a one-off rake in the deploy
  worktree, riding cap's connection).
- Test seams, following the job's existing ones.

## Calls I made (Claude), for Kacper to check

- Delete only for resyncs whose work is not on master; a first import or a
  re-import cannot be deleted.
- Resume puts back the feature the stop interrupted.
- A role found in the code is only suggested, never built by itself.
- A context whose sign-in fails is built from the code; the import goes on.
- The Feedback section shows once the import is not running.
- No stored route list: git diff of the routes is enough.
- The git tool is a separate MCP server rather than more tools on the
  browser; full bare clones, never partial, so it needs no network.
- No mockup file: the screens follow the import page's style, and Kacper sees
  them on production in the morning.
