# Designs setup, feature by feature

Date: 2026-11-02 · Status: draft for Kacper's review · Replaces the setup run of
[Workshop Designs v2](2026-11-02-workshop-designs-v2-design.md) · Pilot: Flosis
(project 14 on app.flosis.com)

## Why

Designs v2, on production since 2026-11-02, builds a project's first master in
one setup run. A crawler signs in to staging as each context and saves a
screenshot and the DOM of every page it can reach by links. Then three large
Claude turns write the design system, all the components and all the screens,
each turn over the whole app. On a real application this cannot work well:

- one turn over every page overflows Claude's context, and an hour-long run
  that fails near its end starts again from the beginning;
- a crawl that only follows links sees pages, not what happens after a click,
  so the designs miss the app's logic;
- how close the result is to the app depends on how well one turn redraws
  dozens of screens.

Kacper wants the setup to write **the whole project and its logic as a
clickable frontend in the project's chosen technology**, as close to 1:1 with
the current app as it can get, so that afterwards every change happens in
threads.

## What success looks like

Kacper fills in the setup form, starts the run and watches its progress. When
it finishes he opens Designs and finds the app there: every context's screens,
the flows between them and their states, built from shared components on the
design system. What is missing or wrong he describes in ordinary Designs
threads.

## Goals

1. **A clickable frontend of the whole app, with its logic.** Screens per
   context (`designs/<context>/<screen>.html`, as in v2), linked the way the
   app's navigation is. Forms lead to the next screen, and modals, tabs, menus
   and the states a person meets (validation errors, empty lists, no
   permission) are there. HTML + CSS now; Vue, React and Angular later (the
   form already shows them as "soon").
2. **A feature map first.** The AI divides the app into features ("projekt
   powinien być podzielony na featury najpierw") from its code and from using
   the app. The map lists each feature's screens, flows and contexts, and
   drives the rest of the run.
3. **Features one after another, each taken by a smaller AI thread.** Strictly
   in sequence, never in parallel. Each reuses the components built so far or
   adds the missing ones, so the component library grows feature by feature
   and later features come out faster and more consistent.
4. **Each feature checked in a browser against the real app** before the next
   one starts: the designed screens look like the app's, and the design works
   (links lead where they should, buttons do what they should, no script
   errors).
5. **On test data, never real data.** The AI may click, create and delete, in
   a test environment the client provides.
6. **Unattended.** From the form to master with no stops; about 10 hours is
   acceptable. The AI may leave notes for Kacper (questions, gaps) for him to
   deal with later, kept to a minimum and never holding the run.

## Non-goals, for now

- Handling a failed or stuck run: retry buttons, fixing a feature from the
  progress screen. Kacper: later.
- Vue, React and Angular output.
- The staff-only Admin panel above all organizations, where this form may
  move.
- Resetting the test environment between features. Kacper rejected it as too
  much: the AI makes the data it needs instead.

## Anti-goals

- Changing or deleting the client's real data, or causing anything outside the
  test environment: real emails or invitations, payments, issues pushed to
  Jira, messages to Slack or Discord.
- An AI that stops to ask. Questions are rare and never hold the run.
- One giant session for the whole app.

## The form

It stays as v2 built it from Kacper's design: Technology (framework, UI system
and version), Repositories (the designs repository and its token; the app
repositories as `owner/name@branch`), and contexts, each with a login URL, a
login and a password. What changes is what that last section means: the
client's **test environment**, which may be staging or even production, with
starting data and a test account per context ("Każdy klient będzie miał
staging lub nawet produkcję, ale po prostu stworzy środowisko testowe z
wstępnymi danymi"). (Call: its copy says so.)

Assumption: Flosis has no staging, so for the pilot its test environment is a
test workspace on app.flosis.com, which Kacper prepares.

## The run

"Build designs" starts it, and it goes through these steps:

1. **Reading the repositories.** Each app repository from the form, at its
   `@branch` (otherwise the repository's default branch), read-only. Today a
   turn reads only the project's own checkout; the form's repositories must
   really be read.
2. **Signing in as each context** to the test environment.
3. **Mapping features.** The AI reads the code (routes, controllers, menus,
   views, front-end code) and uses the app as each context. It writes the
   feature map: for each feature its name, the contexts that have it, its
   screens and flows, the code behind it, and the order the features will be
   built in. It also leaves the notes it can already tell, such as an
   integration the test environment lacks.
4. **Design system.** Tokens, fonts and icons from the app's UI system settings
   and CSS, as v2's first phase does, including its check of the stack against
   package.json and the lockfile.
5. **Features, one by one**, in the map's order. Each feature gets a fresh,
   smaller AI session that:
   - reads the feature's entry in the map, the notes and progress so far, the
     design system and the components built so far;
   - uses the app in the browser as each context that has the feature, on test
     data, and reads the feature's code;
   - writes the feature's screens and flows for every context, reusing
     components and adding the missing ones (each with its README and
     preview, as in v2);
   - checks the result: opens each designed screen next to the app's, compares
     them and clicks through the design's flows, fixes what differs and checks
     again, a bounded number of times;
   - commits, and records the feature's status and notes.

   (Call) The first feature is the app shell and sign-in (layout, navigation,
   header), because every other feature uses it. (Call) The sessions work on
   the setup's branch; they are not separate Designs threads in the thread
   list.
6. **Committing to master.** (Call) The setup's branch lands on master once, at
   the end, recorded as the import's merge, as in v2. Each finished feature is
   a commit on the setup's branch, so a run that stops resumes at the feature
   it was on. Landing features on master one by one would let threads start on
   components the setup is still changing.

## Test data

- The client prepares the test environment and its starting data. Flosis
  never resets it.
- The AI has the source code, so it knows what each feature needs, and the
  prompt has it create the records it needs before it uses a feature: a
  project before it deletes one, a few entries before it checks pagination.
- (Call) It changes and deletes only records it created itself, so the
  starting data stays for the features after it.
- (Call) A state it cannot bring about in the environment (an empty list when
  there is starting data, a rare error) it builds from the view code, and says
  so in a note.
- (Call) It never does anything that has an effect outside the environment
  (see Anti-goals). It builds that action's result from the code and leaves a
  note. It never leaves the test environment's origin and never follows
  sign-out links, as today's crawler doesn't.
- Test-account passwords never reach the model. A tool signs in, as today's
  crawler keeps them out of its arguments, logs, screenshots and DOM
  (`DesignSetupRole#password` is encrypted at rest).

## Form filler

A tool in the AI's browser that fills a whole form at once, "żeby AI się nie
męczyło". It reads the form's fields (label, type, required, options, limits)
and fills each with a plausible value; the AI passes only the values it cares
about. Values may follow the code, such as an enum's options or a validation's
format. (Call) On request it fills a form wrongly instead, to bring up the
validation errors in one step.

## Progress screen

Kacper approved the mockup [setup-progress.html](2026-11-02-designs-feature-setup/setup-progress.html)
("wygląda super!"). It is drawn in his ClearBacklog-3 design's style. From the
top:

- the run's steps, each with its time, and the percent done and time left;
- **Notes for you**: the AI's notes, each naming its feature and that feature's
  status, and marked as blocking nothing;
- **Features**: the feature map. Each feature shows its contexts, number of
  screens, components new and reused, its status (Matches the app; Done · N
  notes; Checking against the app; Up next; To do) and the time it took. The
  feature in progress shows its screens, each done, in progress or to do.

It has no buttons to retry or fix anything, since error handling comes later.
"We'll notify you when master is ready" stays.

## Notes and questions

- (Call) A note is one sentence, names its feature, and is written only when
  something makes the design differ from the app or leaves part of it
  unchecked: test data that is missing, an action not taken, an integration
  the environment lacks, a context that could not sign in.
- The AI never waits for an answer. It takes the most reasonable option, or
  builds that part from the code, records the note and goes on.
- Kacper reads the notes on the progress screen and, after the run, fixes the
  gaps in Designs threads.

## Constraints from what exists

- The designs repository keeps v2's layout, contexts as folders and the leak
  guard: turns write only `design-system/`, `components/`, `designs/` and
  `inspirations/`.
- Prompts are Flosis's own and live in the Flosis library (v2's
  setup-design-system, setup-components and setup-designs entries are
  replaced). They never reach the client's repository.
- A client's AI runs on the project's own API key. Flosis's fallback key,
  `FLOSIS_DESIGNS_SETUP_API_KEY`, is not set on the server.
- Production is one Hostido server (MariaDB 10.11, Solid Queue). Every deploy
  restarts Solid Queue and kills the jobs running at that moment, so a run of
  many hours will be interrupted. It must pick up again on its own after a
  restart, at the feature it was on.
- Headless Chrome has never run on that server (no setup has run on
  production yet), and steps 2–5 need a browser.
- Turns run the Claude CLI with Read, Glob, Grep, Edit and Write only: no Bash,
  no browser. `ClaudeCliService` can already pass an MCP configuration, as the
  automations do.

## Prior art

Anthropic's harness for long-running agents works the way Kacper described: a
first session writes a list of features (200+ in JSON, all marked failing);
each later session takes one feature, tests it end to end in a browser as a
user would, marks it passing only then, and leaves its progress in a file and
in git so that the next session knows where things stand.

- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
- [Harness design for long-running apps](https://www.anthropic.com/engineering/harness-design-long-running-apps):
  adds an evaluator that tests the running app through a browser.

## Left to the builder

- How the AI drives the browser, and how the form filler, the sign-in and the
  screen comparison are built (an MCP server, Playwright, or both). Whether the
  comparison is the AI's judgment of two screenshots, a pixel difference, or
  both.
- Where the feature map and the run's progress are stored (Flosis's database
  or the setup's branch), as long as the client's repository keeps v2's
  layout.
- The bounds: attempts per check, time per feature, the whole run.
- Which model runs which step.
- What becomes of v2's setup code (`Designs::SetupRunJob` and its seven steps,
  `Designs::CrawlJob` and `lib/designs_crawler`, the three phase prompts, the
  progress view), and of a re-import, which v2 runs as a full rebuild on a
  thread.
- Where the browser runs if the Hostido server cannot run it. Find out first,
  before building on it.
