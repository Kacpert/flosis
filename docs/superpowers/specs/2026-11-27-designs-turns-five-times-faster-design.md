# Designs turns five times faster and cheaper — design

2026-11-27. Agreed in chat with Kacper ("tak rozpisz"); this document waits
for his review before any plan or code.

## Why

A design turn of thread 6 (task 565, "multiapp projects in designs",
turn 98) took 23 minutes, 283 tool calls and about $11 at list prices
($15 with the margin), plus a 2-minute on-screen check, for what looked like
a frontend change. Kacper: "24 minut 307 steps!!! PRAKTYCZNIE 15 USD!! …
koszt jest za duży, czas pracy jest za długi, trzeba to zmienić", and
"musimy podnieść wydajność co najmniej 5-krotnie".

What he asked for, in his words:

- Plan first, then execute in parallel on a cheaper model: "zrobić plan a
  całość później wykonać jakimś haiku czy coś, jednocześnie każdy robi swój
  plan".
- Components that really are global: "AI nie patrzy na cały plik tylko na to
  co w danym miejscu się znajduje, a komponenty modyfikuje globalnie — przez
  co potrzeba znacznie mniej zmian, tylko w jednym komponencie".
- Fewer characters, so the AI edits faster: "ograniczyć ilość znaków".

## What a turn costs today

Turn 98, from its transcript on the server
(`~/.claude/projects/…task-565…/c5404c9a-….jsonl`):

| | |
|---|---|
| Wall time | 22.9 min, almost all of it model time (tools took seconds) |
| Requests to the API | 110, 66 of them with 2+ tool calls side by side |
| Tool calls | 283: Edit 174, Read 68, Grep 25, Write 16; 78 files touched |
| Output tokens | 146k; edits and writes are about a third, the rest is thinking (design turns run at the CLI's default effort, high) |
| Context | 81k tokens at the first request (it resumed the session of turn 97, the thread's plan), 385k at the last, 261k on average |
| Cache reads | 28.4M tokens: every request re-reads the whole context |
| Cost at list prices | $11.19 = cache reads $5.68 + output $2.92 + cache writes $2.59 |

Where the steps went:

- **Role copies.** The same screen exists for Admin and for Product Owner, and
  each change was made twice. 20 edits were identical edits repeated in another
  role's copy of a file.
- **One edit per item.** 23 edits went to one file, `designs-components.html`,
  one per component card. 82 edits changed fewer than 200 characters.
- **Whole files read.** The 68 reads brought 284k characters into the
  context, most of them screens read whole, page scripts included.
- **The menu was not the cause.** Only 2 files had their shell or menu include
  edited.

What the screens are made of (Flosis's design repo, master, 2026-11-27):

| | chars | share of the 1.48M in 101 screens |
|---|---|---|
| Extra copies of screens that exist in 2+ contexts (29 names; 23 of them ≥ 90% identical) | 685k | 46% |
| Scripts | 606k | 41% |
| …of which lines that recur in 10+ screens (theme switch, menus, dialogs, toasts…) | 300k | 20% |
| Runs of 3+ of the same component in a row (lists) | 285k | 19% |
| Tailwind class attributes | 119k | 8% |
| What `<x-bug-row>` instead of `<x-include src="components/bug-row/bug-row.html">` would save | 63k | 4% |
| Include attributes repeated on most screens of a role (user, project, role) | ~37k | 2.5% |

The 200 components hold another 632k characters, 33% of them classes, and
their 199 READMEs and 199 previews hold 300k and 592k. A design turn's first
message is about 68k characters: the repo map is 56k of them, and
`design-system/theme.css` (29k) is given whole inside the map. The system text
is another 9.6k.

On 2026-11-24 HAML and Slim were measured on the same repo. They came out at
91% and 90% of the HTML's size, which works out to about 1% of a turn's cost.
The conclusion then was that the context's size is the lever, not the file
format.

Prices behind the estimates (Claude API list, per million tokens; the server
runs on the Max subscription, so these are the CLI's list-price estimates,
which is also what clients are billed from):

| Model | Input | Output | Cache read | Cache write (1 h) |
|---|---|---|---|---|
| Opus 5.5 | $4 | $20 | $0.20 | $8 |
| Sonnet 5.5 | $2 | $10 | $0.20 | $4 |
| Haiku 5.5 (prompts ≤ 100k) | $0.10 | $0.50 | | |

A cache read costs the same on Sonnet as on Opus. A cheaper model halves the
cost of output and cache writes. Only a smaller context and fewer requests cut
the cache reads, and those were half of turn 98's cost.

## Goals

1. **Big requests.** Turn 98's request should finish its round (plan and
   design) in at most a fifth of today's time, and its design work should cost
   at most a fifth of today's ($2.24 at list prices). The design must be as
   good as today's: the on-screen check passes and Kacper accepts the screens.
2. **Small requests.** A one-screen text change is no slower than today, and
   is done without executors.
3. **Change once.** What shows on several screens, or for several roles, is
   changed in one place.
4. **Read only what is changed.** The AI finds the place first and reads
   that, not whole files.
5. **Every cost is counted.** The executors' cost is in the turn's AiRun and
   counts against the turn's cost cap, as the rest of the turn does.

## Non-goals

- **Compact template languages** (HAML, Slim or our own syntax). They were
  measured on 2026-11-24 at about 1% of cost, and Kacper closed the topic
  then. The chat of 2026-11-27 agreed to "decide after measuring", and that
  measurement already exists.
- **Dropping Tailwind.** Classes are 8% of screen characters.
- **Short component tags (`<x-name>`)** and **a shared data file per role**.
  They would save 4% and 2.5%. These can wait until the levers below are
  measured.
- **Changing what turns other than design do.** Plan turns keep their role
  (understand the request, ask what only the person can settle; Kacper,
  2026-11-21). The on-screen check, describe, setup and import turns stay as
  they are; imports already start a fresh session per feature.
- **Flosis running the executors as separate processes.** Considered and
  rejected for now, see "Lead and executors".

## Anti-goals (failure even if it "works")

- Faster but worse: executors produce screens that ignore the repo's
  components, tokens or space rule, or the on-screen check starts failing.
- Small changes get slower because every request goes through executors.
- Executor costs that a client never sees billed, or that slip past the
  turn's cost cap.
- A design repo a developer can no longer read: it stays plain HTML with
  components.
- Another client's design repo breaks because the runtime changed under it.

## Constraints

- **The server's Claude CLI stays at 2.1.328.** Auto-update is disabled, and
  Kacper wants it so ("bardzo ważne żeby nie było aktualizowane"). Everything
  here must work on that version. It has `--agents`, `--tools` and
  `--effort`; its default model is Opus 5.5. Subagents have run on this
  server before: 14 transcript folders of subagents exist.
- **Turns run on the Max subscription today and on API keys later** ("na
  prawdziwej produkcji przejdziemy na API key"). Both must work.
  - Today an own key runs the CLI with `--bare`, which guarantees the server's
    login is never used.
  - In bare mode, CLI 2.1.251 exposed only Read and Edit, with or without
    `--tools` (probed 2026-11-10, never fixed). A keyed project's design turns
    therefore cannot Write, Glob or Grep today, let alone dispatch executors
    (see Phase 0, item 7).
- **Executors share the subscription's limits.** Running them in parallel
  spends those limits in bursts, so parallelism is capped (see "Dispatch").
- **The leak guard.** Turns may only change `design-system/`, `components/`,
  `designs/` and `inspirations/`. `runtime/` changes only through Flosis's
  own template commit.
- **Where the runtime lives.** Gold's `lib/designs_template/runtime/flosis.js`
  is the runtime's source. Published slots get it from Gold. The repo's own
  copy and its README are updated by Flosis's template commit, as in the states
  fold.
- **Server-side expansion mirrors the browser.** `Designs::Includes` expands
  includes in Ruby for Changes. Every new include semantic goes there too;
  the states bug of 2026-11-23 came from missing this.
- **The MCP tools are uploaded by hand.** `lib/designs_crawler/*.mjs` runs on
  the server from `shared/designs_crawler`, and `cap deploy` does not update
  it.
- **Deploys.** Deploy only when no job is claimed and no DesignTurn is queued
  or running. Production is MariaDB and tests run on PostgreSQL, so SQL must be
  portable.
- **Earlier decisions stay.**
  - A thread's first message is planned; a thread made from a task starts
    with a plan.
  - Later messages go to a design turn that may propose first (variant b)
    when a change spans several screens or adds something new. No plan is
    added to later messages.
  - Each page's states live in that page's file, and `<page>-<state>.html`
    files are never written.
  - The space rule and the components rule stay.
  - Designs are plain HTML and CSS, with no build step.
- **Subagents only for edits, never for exploring.** Design turns lost their
  subagents on 2026-11-10 (184ec4d) because a subagent spent minutes mapping
  the repo, which Claude then read again itself. Executors here never explore:
  the lead names the files they own.

## The design

### 1. A new Claude session once the old one has grown or gone cold

Today a thread resumes one session for all its turns, so its context only
grows. Task 551's thread grew from 31k to 485k tokens over 12 turns. Turn 98
ended at 385k, and thread 6's next message would have started from there.
After an hour's pause, the whole context is written to the cache again at $8
per million tokens.

Which session a turn runs in:

- **A build that answers a plan or a proposal resumes that session.** These
  are `design_as_planned!`, the person's reply to it, and "Design with these
  proposals" (`after_plan?`). The build keeps what the plan or proposal read.
- **Any other turn resumes the thread's session only while it is warm and
  small:**
  - its last turn ended less than 55 minutes ago (the CLI's cache lives an
    hour);
  - its last request's context was under 150k tokens. The turn keeps this
    figure, taken from the stream's usage.

  Otherwise the turn starts a new session. Kacper's quick corrections in a
  row stay quick this way, and a long thread stops growing. Both thresholds
  are my call, to be tuned after measuring.
- **`resolve_conflicts` and `components` turns always start new sessions.**
  The new id is kept on the chat session, as `converse`'s retry already does.
- **A new session gets what a first turn gets today:** thread, focus screen
  and state, task, current description and the repo map. It also gets two new
  sections:
  - **"This thread so far":** the person's messages and the AI's replies as
    the chat shows them, oldest first. Past about 20k characters, the oldest
    messages are cut.
  - **"Changed on this branch":** the screens and components the branch has
    changed from master.
- **The map no longer carries `theme.css` whole.** It names the file, and the
  turn reads what it needs.
- **Design turns get `--effort medium`** (a new `DesignTurn::DESIGN_EFFORT`).
  Plan, check and describe turns already run at medium.
### 2. Lead and executors (big design turns)

**The lead.** The design turn's own agent is the lead: Opus 5.5 at medium
effort. Its tools are today's (Read, Glob, Grep, Edit, Write, copy_file), the
new `outline` tool (section 4), and the CLI's Agent tool, limited to the two
executors below.

**The executors.** They are defined for each turn with `--agents`. They are
not files in the client's repo, and not agents installed on the server.

| Agent | Model | For |
|---|---|---|
| `designs-builder` | Sonnet 5.5 | New or changed UI, built from a brief |
| `designs-editor` | Haiku 5.5 | Mechanical changes that the brief spells out exactly (this text to that text in these files; this attribute on these includes) |

- **Executors' tools:** Read, Glob, Grep, Edit, Write, copy_file and `outline`.
  They get no Agent tool, so an executor never dispatches another one.
- **Executors' prompt.** It carries the repo's conventions from
  `Designs::Prompt`: components and includes syntax, states, the space rule,
  style, and copy_file for new screens. A subagent may not see the lead's
  system prompt (verify in Phase 0). The brief carries the direction.
- **If Haiku cannot be used.** If Phase 0 shows that Haiku 5.5 cannot run on
  this CLI or login, or its trial edits break markup, the editor runs on
  Sonnet 5.5.
- **Turns on an own key** dispatch executors only once Phase 0, item 7, has
  shown how. Until then they run lead-only.

**Small or big.** If the lead can finish a request by changing at most three
files, it makes the changes itself. Anything bigger is planned and dispatched.
The threshold is my call and can be tuned after measuring.

**How the lead handles a big request:**

1. **Finds before reading.** It uses Grep with line numbers, `outline`, and
   Read with offset and limit. It reads a file whole only when it will change
   most of that file itself.
2. **Splits the work into pieces.** Each piece owns files that no other piece
   touches. Shared things go first: components, and page components that
   several screens use (6a). The screens that use them come after.
3. **Writes a brief for each piece:**
   - the goal;
   - the files the piece owns and the files it may create;
   - for each file, what changes, with the exact strings people will see;
   - which components to use or change;
   - what not to touch;
   - what to report back, in at most five lines.
4. **Dispatches.** All the independent pieces of a phase go out in one
   message, so they run in parallel. At most five run at once (my call). The
   lead waits for them, then starts the next phase.
5. **Reviews.** It reads the reports. It uses Grep for what must be gone (an
   old string) or present (a new component's include). It fixes small
   leftovers itself, and sends one more executor only for a piece that was
   missed.
6. **Replies as today,** with the `Designs::TurnOutput` blocks. Flosis then
   commits, publishes and starts the check as it does now.

Turn 98 would have become four or five pieces. The longest of them sets the
wall time, and each executor's context stays at tens of thousands of tokens
instead of hundreds of thousands.

**Why the CLI's own subagents, and not Flosis running several CLI processes.**
The CLI's subagents keep a turn as one process: one stop, one commit, one cost
record, one check. Flosis's code changes only in the CLI's flags, the prompts,
the activity and the recorder. With separate processes, Flosis would have to
orchestrate them, merge their work and handle each one failing. If Phase 0
shows that the CLI cannot limit or cost its subagents, this is the decision to
revisit, with Kacper.

### 3. Rules that cut steps

These go into `Designs::Prompt`, for the lead and the executors alike:

- **Change once.** What shows on several screens changes in its component or
  page component, never screen by screen. A text repeated within a file
  changes with one Edit and `replace_all`.
- **One response per file.** All the edits a file needs go in one response,
  as several Edit calls side by side, after one read.
- **old_string costs output too.** It is written out just like the new text,
  so it should be short and unique. A file is rewritten with Write only when
  most of it changes.
- **Read what you change.** Find the place with Grep or `outline`, then read
  those lines.
- **New components** get a README.md with one line of purpose, their
  parameters and their states. They get a preview.html only when they have
  more than one state; the Library already falls back to the component file
  (`designs_module_controller.rb:183`). Existing previews stay.
- **A new screen for several roles** is one page component plus a thin screen
  per role (6a).

### 4. The `outline` tool

`outline` is a new tool in `flosis_files` (`lib/designs_crawler/files.mjs`).
Given a path in the design repo, it returns the file as an indented outline:
landmarks, elements with an id or states, and each include with its src and
attributes (long values shortened), each with its line range. The lead and the
executors then read just those lines.

The plan turn has no MCP today, because it only reads. Giving it `outline` is
left to the builder.

### 5. What the chat shows and what is recorded

- **Steps.** `Designs::TurnActivity` skips subagents' events today
  (`parent_tool_use_id`). Each executor will show as one line in the turn's
  steps: its piece (the Agent call's description), its model, the file it is
  on and its step count, then the first line of its report. The lead's own
  steps show as today, and the turn's step count counts every step.
- **Stop.** Stop ends the whole turn, executors included, because it is one
  process.
- **Cost.** There is still one AiRun per turn. It includes the executors'
  cost, tokens and models, so Consumption and billing (SCRUM-70/71) charge the
  whole turn.

### 6. The design repo, slimmed

#### 6a. Screens shared by roles

This is the largest lever: 46% of screen characters, and the doubled edits of
turn 98.

- **Shape.** Each screen that exists in several contexts gets its body moved
  into `components/<screen>-page/<screen>-page.html`. The repo already has
  `designs-imports-page` and `designs-library-page` made this way. Each role's
  screen file keeps its head, its shell include with that role's attributes,
  and the page include.
- **Role differences** inside the page component are marked
  `data-show-for="<context> …"` or `data-hide-for="<context> …"`, where a
  context is a folder under `designs/`. The runtime applies them from the
  screen's path, before states. `Designs::Includes` applies them the same way.
- **What stays the same.** Gold's screen model stays
  `designs/<context>/<screen>.html`: URLs, View as, chips, short links,
  Changes, Accept and Finish are unchanged.
- **To verify.** A change to a page component must show every role's screen
  as changed, in chips and in Changes.

#### 6b. Behaviors in the runtime and in components

20% of screen characters are script lines that recur in 10+ screens.

- **Inventory.** Count the screens' scripts. The behaviors many screens share
  (theme switch, sidebar fold, top-bar menus, dialogs, toasts; the inventory
  decides the list) move into `runtime/flosis.js`, driven by the `data-`
  attributes the screens already carry (`data-theme-toggle`,
  `data-sidebar-toggle`, `data-menu-toggle`/`data-menu-panel`, …). Dialogs
  get two new ones, `data-dialog-open="<id>"` and `data-dialog-close`.
- **Behavior that belongs to one component** goes beside it as
  `components/<name>/<name>.js`. The runtime loads it once on each page that
  shows the component, after the includes. Today a component's own script
  never runs, because includes go in through innerHTML, and that is why
  behaviors were pasted into the pages.
- What is truly one screen's own stays in that screen.
- **No double binding.** A page that still has its own handlers (any client's
  repo not converted yet) must work exactly as before. The mechanism is the
  builder's call: an opt-in marker per page, or new attribute names.
- **Changes.** The Changes view behaves the same as the page.

#### 6c. Lists from data (only if needed)

- **The tag.** `<x-include src="components/<name>/<name>.html"
  each="<path>.json">` renders the component once per object in the JSON
  array, with each object's keys as the include's attributes (states
  included).
- **Limits.** Rows that have children of their own stay markup. The JSON file
  sits beside what includes it, and `Designs::Includes` expands it the same
  way.
- **What it is worth.** Lists are 19% of screen characters. The gain is mostly
  in edits: rewriting a list becomes one Write of a compact file, instead of
  an Edit per row.
- **When to build it.** Only if the benchmark, after 6a and 6b, is still short
  of 5×.

#### 6d. Converting Flosis's design repo

The repo is RubyOnSaas-wiki/flosis-app-design (project 15). It is converted
the way states were folded on 2026-11-22:

- **Who does the work.** Scripts where the change is mechanical, agents per
  screen family otherwise.
- **Checking.** Every screen and every state is compared in pixels before and
  after, on a tall window.
- **One commit.** The repo's runtime copy and README are updated in the same
  commit.
- **Repeatable.** The conversion is built as tooling that gives the same
  result every time: scripts for the mechanical steps, and one guide for the
  agent steps. Open branches need it, and so does the B1 benchmark
  (section 7).
- **When.** Kacper says when master is converted. At the time of writing,
  thread 6 (task 565) is open and changes the very Designs screens that would
  move into page components. So the conversion either waits until that
  branch is merged, or runs on the branch too.

Other clients' repos keep working unconverted, and are converted when their
owners want it.

### 7. Phases, each measured

| Phase | What | Gate |
|---|---|---|
| 0 | Verify the CLI (below) | Every answer known; stop and rethink section 2 if subagents cannot be limited or costed |
| 1a | Sessions (section 1), effort medium, theme.css out of the map, rules (section 3) | B1 and B2 measured, results to Kacper |
| 1b | Lead and executors, `outline`, activity, recorder (sections 2, 4, 5) | B1 and B2 measured |
| 2 | 6a, 6b, conversion (6d); 6c only if short of 5× | B1 at goal; B2 no slower |

Each phase ships on its own, after its tests pass, with the usual deploy
gate.

**The benchmarks:**

- **B1: thread 6's first message (turns 97 and 98).** The same request is
  run on a scratch thread, from the commit thread 6 started from (the
  DesignTurn records give it). For Phase 2, the conversion runs on a copy of
  that commit first.
  - Baseline: plan 35 s; design 22.9 min, $11.19, 283 tool calls, context
    81k → 385k.
  - Goal after Phase 2: plan and design in ≤ 4.7 min together; design at most
    $2.24; the check passes; Kacper accepts the screens.
- **B2: a one-screen text change, sent as a follow-up.**
  - **B2a:** right after a build, while the session is warm.
  - **B2b:** on a session that has gone cold (forced in the test).

  Both are measured on today's production first. Both must stay no slower,
  and use no executors.

Each B1 run costs a few dollars of subscription usage.

## Verify first (Phase 0)

On the server's CLI 2.1.328, with the subscription login, run a tiny
throwaway session that dispatches both executors, and check:

1. **Models.** `--agents` definitions with `model` set to `claude-sonnet-5-5`
   and `claude-haiku-5-5` both run, and the transcript names the model each
   one actually used.
2. **Parallel runs.** Two Agent calls in one message run at the same time.
3. **Stream and cost.** The executors' stream-json events carry
   `parent_tool_use_id`. The result's `total_cost_usd` and `modelUsage`
   include the executors.
4. **Cost cap.** `--max-budget-usd` counts the executors.
5. **Tool limits.**
   - Executors get only the tools in their definition that the session also
     allows.
   - The lead's Agent tool can be limited to the two executors, with no
     general-purpose or Explore agent.
6. **Effort.** `--effort` reaches the executors, or there is another way to
   set theirs.
7. **Own key.** Check whether bare mode on 2.1.328 still exposes only Read
   and Edit. The stream's init event lists the tools, so no valid key is
   needed.
   - **If it does:** a keyed turn runs without `--bare`, in a config dir of
     its own (`CLAUDE_CONFIG_DIR`, empty) with only `ANTHROPIC_API_KEY` set.
   - **What proves the guarantee still holds** (a keyed run never uses the
     server's login):
     - the init event names the key as the credential (`apiKeySource`);
     - a run given a deliberately wrong key fails with an authentication
       error.
   - This would also fix keyed design turns that cannot Write or Grep today.

**If an answer is no:**

- Haiku fails → the editor runs on Sonnet.
- 3 or 4 fail → the recorder sums the executors from their transcripts
  (`<session>/subagents/`), and the cap is enforced from the stream.
- 5 fails → executors get the whole session's tool set, and the rules keep
  them to their files.
- 7 finds no way → keyed turns stay lead-only, and Kacper hears of it before
  turns move to API keys.

Check the result with Kacper before Phase 1b if any of these fall-backs is
needed.

## Left to the builder

- **Prompts.** The exact wording, and how much of the Flosis library the
  executors get.
- **Briefs.** Their format, within what section 2 lists.
- **`outline`.** Its output format, and whether the plan turn gets it.
- **Behaviors.** The no-double-binding mechanism (6b), and the attribute
  names for new behaviors. Keep the existing names where they exist.
- **Chat layout.** How executor lines look, in the style of the existing
  steps.
- **Tooling.** The scripts and agents used for the conversion.

## Decisions and who made them

- **Kacper:**
  - at least 5× faster and cheaper;
  - plan first, then parallel execution on cheaper models;
  - components edited once, and the AI reads only the place it changes;
  - fewer characters;
  - write this up as plan plus executors plus a richer runtime, with a
    shorter syntax only after measuring (closed by the 2026-11-24
    measurement).
- **Mine, open to his review:**
  - **Executors:** the CLI's own subagents rather than separate processes;
    Sonnet 5.5 builders and Haiku 5.5 editors.
  - **Sessions:** a build after a plan or proposal resumes that session; any
    other turn resumes only a session that is warm (< 55 min) and small
    (< 150k tokens). Effort medium for design turns.
  - **Keys (security-sensitive, please check):** if bare mode still lacks
    tools, keyed turns run without `--bare`, in an empty config dir holding
    only the key.
  - **Conversion:** built as repeatable tooling, so open branches and the
    benchmark copy are converted the same way.
  - **Limits:** a three-file threshold for small requests; at most five
    executors at once.
  - **Repo shapes:** page components named `<screen>-page`;
    `data-show-for`/`data-hide-for`; `each` built only if needed.
  - **Postponed:** short tags and a role data file.
