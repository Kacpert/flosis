# Designs: a senior UX/UI partner that proposes first and checks its own screens

**Date:** 2026-11-21
**Status:** Draft for Kacper's approval (builder check done)

## Why

Design thread 4 (SCRUM-70 "Add token calculations", project Flosis) shows the
problem. After the first build (30 minutes), Kacper spent 7 more turns, about
32 minutes of waiting, fixing things a senior designer would have caught:

- where the cost goes: 4 turns (~21 min). Each time the AI added a line of its own,
  even after "this should be subtle … not consume space";
- the format: he had to invent "€0.68" alone when the month equals the total,
  and "€0.68 (none this month)";
- the 30% margin shown on the organization's own Consumption screens;
- a wrongly named area.

The AI never proposed any of this. Today only the first turn of a thread made
from a task plans. Every later message builds at once, and so does every message
of a thread started by typing ("do not stop to ask" in the base prompt). The
thread's AI cannot see the rendered screen, so it cannot notice text cut off on
a narrow screen.

Kacper (2026-11-21):

- the AI should be a senior UX/UI designer who catches such things and helps at
  once: "bardziej doradzać w dialogu … pisać bardzo krótko ale treściwie i pomagać
  projektować";
- like superpowers: first agree the UX and UI direction, then implement;
- "najpierw ustala jak rozumie danego taska chyba że jest to oczywiste i wyłapuje
  potencjalne luki ux/ui no i sugeruje format";
- who sees what, it works out itself from the project notes and the task; no
  questions every thread that users of one project would answer the same way;
- what matters is each view's main purpose: understand it, never disturb it,
  extend it with the new requirement, and present it for a person with limited
  attention. When the task says nothing of where or how, propose it, respecting
  each view's purpose;
- by default economical with space, "ale bez przesady": minimalist, simple, nice;
- the thread's AI gets a browser and checks the screen, and it says "done" first,
  "tak że jak ktoś czeka to żeby już sobie mógł sprawdzać";
- variant (b) below, as a test. He expects to go back to (c) after testing.

The research behind this is in `reports/AI jako senior projektant UX UI.md` (not
committed). In short: a "senior designer" persona alone does not help, because
models are weakest at minimalism and at who sees a screen. What helps is concrete
rules, proposing with a default instead of asking, one decision at a time, short
replies, and a look at the rendered screen.

## Goals

1. **Start of a thread.** Before the first build, the AI posts a short proposal:
   - how it understands the request (skipped when obvious);
   - the UX/UI gaps it sees, each with its proposal;
   - where things go;
   - the format of every new value, with each variant as an exact string.

   It builds nothing until the person answers or clicks "Design with these
   proposals". With nothing to decide, it says so and designs at once, as the
   task plan does today. This applies to threads from a task and threads started
   by typing.
2. **Later messages, variant (b).** A direction or a new thing gets a proposal
   first, with no build. A concrete instruction is built at once, with one sentence
   on what it costs or what the AI would do better.
3. **Design principles in every thread turn**, as a Library skill (below).
4. **Replies of at most three short sentences**, with exact strings, no file names.
5. **A check after every build.** The reply says the work is done and that the AI
   is now checking it on screen. The preview is already up to date. A check turn
   with a browser then looks at the changed screens, wide and narrow, fixes only
   what broke on screen, and adds one line.

## Non-goals

- No memory of the owner's rules across threads.
- No rendered alternatives: directions are described in words.
- No change to the Details chat, setup runs, imports, the components turn or the
  base prompt's text.
- No mode switch for the person.

## Anti-goals (it fails even if it works)

- It asks who sees something, or anything the project notes, the task or an
  earlier answer already settle.
- It stops to propose on a clear instruction.
- Its messages run past a few sentences, or it asks several questions at once.
- The person waits for "done" while the AI checks.
- The check redesigns instead of fixing what broke.

## Approaches

The main question is how, under (b), the AI tells "propose first" from "build
now".

1. **A plan turn before every message.** The plan turn cannot write files, so the
   gate is certain. But every concrete instruction waits for an extra turn
   (~30–60 s) and gets a plan line before it is built.
2. **A plan turn at the start, and the design turn decides afterwards (picked).**
   - The start goes through the plan turn, which already exists for task threads
     and is extended to typed threads.
   - Later messages go straight to a design turn. For a direction it changes no
     file and only proposes.
   - Instructions are built at once, and switching to (c) means dropping one
     rule.
   - The risk is that it sometimes builds where it should have proposed. Then the
     rule is tuned.
3. **A fast sorter** (a small model, a few seconds) sends each message to a plan
   turn or a design turn. It is sure and quick, but it is one more moving part, and
   it is thrown away if (c) wins.

Approach 2 was my call: Kacper gave the outcomes and left the how to me. It keeps
"a concrete instruction is built at once", and it is closest to (c).

The check has one sensible way: a turn of its own after the build. Checking
inside the design turn would make the person wait for "done", against his ask.
Checking only before merge would not check what he looks at.

## The design

### 1. The start: a proposal before the first build

- **Thread from a task.** The plan turn stays as it is (read-only tools, 300 s,
  $3, effort medium, `carry_on`, `go!`, "Design with these proposals"). Its request
  is rewritten to Goal 1.
- **Thread started by typing.** The first message, which names the thread, now
  queues a plan turn instead of a design turn. The plan turn's request is the
  person's own text. What a plan does is told in the message's "This turn" section,
  so both kinds of start share one text.
- **What the plan replies:**
  - a `<summary>` of at most about four short lines: the understanding, the
    placement, and the format with each variant as an exact string;
  - `<missing>` blocks only for decisions a standard cannot settle, each ending
    with "Proposal: ...".

  With nothing open, it ends with "No doubts, designing now.", and `carry_on`
  starts the design.

### 2. Later messages: direction or instruction (variant b)

A design turn answering a person's message gets one more rule in its "This turn"
section. Like `SCREENS_ONLY`, it says it replaces what the base prompt says about
never stopping to ask:

- **Direction or new thing:**
  - new information or a new control;
  - a new place on a screen;
  - a change across several screens;
  - a request about how something should come across ("subtle", "cleaner")
    rather than exactly what to do.

  For these the turn changes no file. It replies as a plan does, with a short
  proposal and `<missing>` blocks with proposals.
- **Concrete instruction:** it builds at once. The reply adds one sentence on what
  the change costs, or what the AI would do better.

"Update designs", after the task's description changed, goes through the same
rule. A change that brings new information or a new place gets a proposal
first; a change of wording is built at once.

A design turn that changed no file and ended with open questions counts as a
proposal:

- "Design with these proposals" shows under it (`go!` accepts it, as it accepts
  a plan);
- the next design turn is told, as after a plan, that the proposal is settled
  and it must not ask again (`AFTER_PLAN`), so the chat cannot loop.

Switching to (c) later means this rule leaves the design turn. Later messages then
build at once, and the start keeps its proposal.

### 3. The principles: a Library skill, "Senior product designer"

The skill is a new active `skill` entry, so every thread turn gets it: plan,
design, check and components. Setup runs do not, because they compose without
skills. A data migration creates it, unless an entry with its key exists. Flosis
staff then tune it in the Library, without a deploy. Its content, written short
and as a list:

- **The view's purpose first.** Know what each view is for. A change serves that
  purpose and never competes with it; it extends the view, in the view's own
  style.
- **Limited attention.** One main thing per view. Secondary information is quiet:
  the size and colour of the metadata beside it. Related things are grouped. The
  essentials can be seen at a glance, and the detail is one step away.
- **Minimal and simple by default.**
  - Choose the simplest good-looking solution.
  - Be economical with space: before adding a row, line, card or label, look for
    a place that already exists.
  - Add one when it earns its place, and say why. This is a default, not a ban.
- **Placement the task does not give:** propose it, and respect each view's
  purpose. A working view stays a working view, and the full picture goes on a
  page of its own.
- **Values:**
  - For each figure, count or date a change shows, design each variant: equal to
    the total (one figure), none this period ("(none this month)"), never any
    (nothing shown), unknown (never shown as 0), very small, very large.
  - Name each variant as an exact string.
  - Put the variants worth judging in the screen's state switcher.
- **Audience.** Who sees which view comes from the project notes, the task and the
  context folders; never ask. A business's own figures (its costs, margins,
  internal rates) stay off its customers' screens.
- **Don't re-ask.** Never ask what the notes, the task or an earlier answer
  settle, nor what any thread of the project would answer the same way.
- **Replies:** at most three short sentences, exact strings in quotes, no file
  names.

### 4. The check after a build

- **When it runs.** A design turn that made a commit queues a `check` turn at
  once, hidden, in the same Claude session.
  - Flosis ends the design turn's reply with a fixed sentence: "Checking it on
    screen now; the preview is already up to date."
  - The live block reads "Checking".
  - No check follows a plan, a turn that changed nothing, a components turn, a
    resolve-conflicts turn or another check.
- **Its own session.** The check runs in a fresh Claude session, not the thread's.
  Otherwise its screenshots would ride along with every later turn, and a stopped
  check would stay in the thread's history. It is given:
  - the person's request;
  - the design turn's summary;
  - the screens and states that turn changed.

  The next design turn's message says what the check changed.
- **While an import runs.** The host has room for one browser at a time: an
  import's takes most of the ~240 threads the host allows. So a check that finds
  an import unit running is skipped with a note: "Not checked on screen: an
  import is using the browser." Imports run for hours, so waiting makes no sense.
  Checks share the `designs` worker with design turns, as other threads' turns do
  today.
- **What it looks at.**
  - The tools are the file tools plus a design-only browser: open a design of the
    repo, take a screenshot of it at a given width, click through it, and
    check_design. There is no app and no sign-in.
  - It opens each screen the design turn changed (at most 6) at the canvas size
    (1160 × 860) and at a narrow width (1024).
  - On each, it looks for:
    - text cut off or overlapping;
    - something pushed onto a new line;
    - broken includes or links, and script errors;
    - the changed states in the state switcher.
- **What it does.** It fixes only what broke on screen and changes nothing else. A
  fix is a commit, published like any turn's. Its reply is one line, such as
  "Checked on screen: the cost was cut off at 1024 px; it now wraps." or "Checked
  on screen: looks right wide and narrow."
- **When the person writes meanwhile.** Their message stops a waiting or running
  check, and nothing the check changed is kept. Their turn runs next and is checked
  after it builds.
- **Bounds.** 600 s, $5, effort medium. A check that cannot run (say the browser
  does not start) posts a note and fails as any turn does. "Try again" reruns the
  check.
- **The browser.** It comes from `lib/designs_crawler`, extended for a design-only
  use. `cap deploy` does not update `shared/designs_crawler` on the server, so the
  changed `.mjs` files are uploaded by hand at deploy.

### 5. Replies

The reply rules live in the skill, so setup runs keep theirs. The commit's first
line stays at most 72 characters.

## How we'll know

Kacper tests (b) on real threads. Before that, the builder replays thread 4's
first request on a fresh Flosis thread and checks:

- the plan proposes the placement on existing rows and the "(none this month)"
  variant;
- no margin shows on the organization's screens;
- replies stay within three sentences;
- the check catches a cut-off on purpose.

## Calls made for Kacper (check these)

- Approach 2: a plan only at the start, and the design turn tells direction from
  instruction.
- "Update designs" follows rule (b).
- The principles go in a Library skill, editable without a deploy. The base
  prompt stays as it is.
- The check:
  - runs in its own session;
  - looks at 1160 and 1024 px, at most 6 screens;
  - runs on 600 s / $5 / effort medium;
  - is skipped during an import;
  - is stopped by the person's next message.
- Flosis, not the AI, writes the sentence "Checking it on screen now; the preview
  is already up to date.", so it is there exactly when a check follows.

## Left to the builder

- The exact wording of the skill and of the "This turn" texts. Keep in mind the
  leak guard refuses twelve words in a row of any Library text in the repo.
- The skill's key and name.
- The check's widths, screen limit and wording.
- How the browser server gets a design-only mode and a screenshot of a design
  (extend `browser.mjs` or add a small server).
- How a design turn is recognised as a proposal (a flag on the turn, or derived).
