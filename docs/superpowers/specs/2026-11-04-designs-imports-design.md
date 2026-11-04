# Designs imports: see, answer, retry, add and resync

Date: 2026-11-04 · Status: draft for Kacper's review · Builds on
[Designs setup, feature by feature](2026-11-02-designs-feature-setup-design.md),
whose non-goals ("retry buttons, fixing a feature from the progress screen:
later") this takes up · Pilot: Flosis (project 15, test workspace on
app.flosis.com, designs repo RubyOnSaas-wiki/flosis-app-design)

## Why

The first feature-by-feature import of Flosis ran on 2026-11-03 from 01:40 to
06:50. It mapped 11 features and built 6. Five failed: two because the AI's
answer could not be parsed, three because Claude's session limit ran out
("resets 8am") and every feature after that failed in seconds. The run still
ended as approved, and the progress screen redirects to Designs once a run is
done, so:

- Kacper cannot see the import's status at all after it ends: "nie widzę
  nawet statusu tego importu";
- he cannot retry anything, answer anything or add anything: "nie mogę
  niczego ponowić nic odpowiedzieć nic dodać";
- his only way to learn what is missing is to click through the designs
  himself: "mogę tylko przeklikać żeby samemu to określić".

What he wants instead, in his words: when something did not work (an
integration on the test account, say), he checks it, fixes it on the test
account and tells the AI it can go on scanning. And when developers later
build something the designs lack, or build it differently, he wants to resync:
"resynchronizacja nowe featury oraz resynchronizacja to co zostało zrobione".

## What success looks like

After an import Kacper opens Designs and sees, in one line of the left panel,
that the import finished and that 5 features need him. The Imports page tells
him in plain words what each problem was. He fixes the Jira connection on the
test account, writes "connected Jira, go on", and that feature is rebuilt; he
presses Retry on the ones the session limit stopped; he adds a feature the map
missed by describing it. Weeks later, after developers changed the app, he
starts a new import from the same page and master is updated with what they
built. Where they changed a screen he had redesigned in a thread, the import
does not overwrite his design: it shows him what would come in, and he
accepts or rejects it.

## Goals

1. **Imports stay visible.** Every import (the first one from the setup, and
   every later one) has a page that stays after it ends: what was built, what
   was not and why, and what is waiting for him.
2. **Two-way.** Where the AI is blocked by something only Kacper can fix, it
   says so, and his reply sends that feature back to work, with what he wrote.
3. **Retry.** A feature that could not finish can be retried, alone or all at
   once, optionally with a word to the AI first. A retry rebuilds only that
   feature; it never starts the import over.
4. **Missing feature? Add.** A feature the map missed can be added by
   describing it; the AI investigates and builds it like any other.
5. **Resync from the app.** A new import, started from the Imports page,
   updates master with what changed in the app since the last import: new
   features developers added, and features they changed. Where an update
   would replace a design change approved in a thread, it waits: the AI shows
   what comes in and he accepts or rejects it (Kacper: "to pozostaje do
   decyzji usera AI powinno pokazać co wchodzi a User powinnien to albo
   zaakceptować albo odrzucić").
6. **Everything reuses the setup's inputs**: the contexts and their saved
   sign-ins, the repositories, the stack and the design system already on
   master. Nothing asks for the form again.
7. **Results go straight to master** ("od razu master"), and what is built is
   deployed to production at once, as everything else is.

## Non-goals

- Time & HR in the Flosis designs. Kacper: "w ogóle nie powinno być i to jest
  ok". The map leaving a product out is fine.
- Imports that start by themselves (on a deploy, on a push to the app repo).
  For now the user starts a resync. (Kacper: "user może go tutaj triggerowac".)
- Vue, React and Angular output.
- Reviewing an import's changes before master, except the ones that would
  replace a thread's work (see When an update meets a thread's work). For the
  rest Kacper chose master directly ("od razu master").

## Anti-goals

- An import that ends looking done while features failed.
- A blocker that holds the whole run. One feature may wait for Kacper; the
  others go on (the setup design's "never holding the run" still holds).
- Badges and counters scattered over the UI. Kacper: no badge, one line.
- An import that replaces a design change approved in a thread without his
  Accept, whether developers touched that feature or not.

## Where it lives

Mockups: [import-page.html](2026-11-04-designs-imports/import-page.html) (the
page; Kacper: "Wygląda wszystko dobrze", with "Add a feature" renamed to
"Missing feature?" · Add),
[imports-link.html](2026-11-04-designs-imports/imports-link.html) (the link,
drawn after his "Imports", one line, no badge) and
[review-card.html](2026-11-04-designs-imports/review-card.html) (a resync's
review card, drawn after his answer on what wins).

- **The link:** "Imports" is a fourth line in the Designs left panel, under
  Design system, Components and Merge history, opening in Designs as they do.
  One line, the same size as theirs, no badge, no pill, nothing in the app's
  sidebar. It is **highlighted whenever an import has finished and has not
  been opened since** (Kacper: "to zawsze się powinno zapalać jak się import
  skończy"). (Call) "Finished" also means a batch of retries, replies or added
  features he started has finished, and "opened" is per person: the line stays
  lit for each person who has not opened that import since. Cards waiting do
  not keep it lit: "N need you" shows on its right while any card waits, lit
  or not. Otherwise it is a plain line with the date of the last import. (The
  mockup's caption, "lit when something waits", is superseded by this.)
- **The Imports page** lists imports newest first: the first import ("First
  import · from app.flosis.com", dates, "6 of 11 features built", "5 need
  you"), then later ones ("Changes since Nov 3 · 3 updated · 1 new · 2 need
  you"). A button starts a new import (see Resync).
- **An import's page**, from the top:
  - its title, when it ran, as which contexts, and "N of M features built ·
    K need you";
  - **while it runs**, its progress: the steps, percent, time left and the
    feature in progress, as the approved progress screen has them. (Call) This
    page replaces the progress screen, which today disappears when the run
    ends; the setup form leads here.
  - **Needs you**: one card per feature that needs him, worst first (Call:
    reviews after the problems), each with what happened in plain words and
    its actions (below);
  - **Built**: one line per finished feature, with its screens, components
    (new and reused) and notes, the notes expandable, and a link to open the
    feature's screens;
  - **Missing feature?** with a description field, the contexts to use, and
    **Add**.
- (Call) The "master is ready" notice the setup sends once leads to the
  import's page.
- (Call) Anyone with the Designs permission sees Imports. Starting an import
  and every action on a card (Send and continue, Retry, Add, Accept, Reject,
  Set aside) needs the Configuration permission, as the setup's own actions
  do.

## Statuses a feature can end in

What Kacper sees on a card, from what actually happened:

| What happened | Card | Actions |
|---|---|---|
| The AI is blocked by something only he can fix (an integration not connected on the test account, data it cannot create, a context that cannot reach the feature) | **Waiting for you**, with the AI's question | reply field + **Send and continue**; Retry |
| The AI's answer could not be read, or the turn crashed | **Couldn't finish**, with the reason | **Retry**; **Tell the AI something first…** |
| Claude's session or usage limit ran out | **Not started** (or stopped), with when the limit resets | **Retry**; resumes by itself after the reset (below) |
| A resync (or any later import work) would change what a thread put on master | **Review what comes in**, listing what comes in, what of the thread's work is kept and what is replaced | **Accept**; **Reject**; **Tell the AI something first…** |
| Built, with notes | in **Built**, "Done · N notes" | open, read notes |

(Call) Every card in Needs you but a review can also be **set aside** ("Not
needed"): it moves to a short Set aside list under Built and stops counting
in "N need you", so a feature he decides to leave never nags. A review's
Reject does the same for it.

A finished import with any card in Needs you is "finished, N need you", never
plain done.

## How the AI's side changes

- **Blockers.** Today a note never blocks and the AI builds around a gap. Now
  the AI can end a feature as *waiting*, with one question for Kacper, when the
  gap is one he can close on the test account and the feature cannot be built
  honestly without it. (Call) The feature stops; the run goes on with the next
  feature. Gaps the AI can work around stay ordinary notes.
- **Send and continue.** His reply resumes that feature where it stopped: the
  AI gets its notes and progress for the feature and his reply, checks what he
  said (signs in again, looks again) and goes on. What the feature already
  committed stays.
- **Retry** runs the feature again from the start of the feature, keeping
  what earlier features built; "Tell the AI something first…" adds his words
  to that run.
- **Session limit.** When Claude answers that its limit ran out and says when
  it resets, the import pauses until then and resumes by itself, instead of
  failing every feature after. The card for the feature it stopped on says so
  meanwhile.
- **Unreadable answers** are retried by the import itself (Call: up to two
  more times) before the card says Couldn't finish.
- **Missing feature? Add** gives the AI the description and contexts; it finds
  the feature in the code and in the app, adds it to the map and builds and
  checks it like the others.
- **Proposals.** Where an update would replace a thread's work, the feature
  ends as a proposal for him to accept or reject instead of landing (see When
  an update meets a thread's work).
- (Call) Retries, replies and added features of a finished import run one at
  a time, in the order he asked for them, as one queue per project.

## Resync: a new import from the app

Started from the Imports page by someone with the Configuration permission.

- **Starting point.** Every import records the commit of each app repository
  it read. A new import reads the app repositories at their branches now and
  takes the diff from the last import's commits.
- **What changed.** From the diff the AI decides which features of the map the
  changes touch, opens only those in the browser as their contexts, compares
  them with the designs and updates the designs to what was built.
- **New features.** From the diff and the app it finds screens and flows the
  map does not have, adds them to the map, builds and checks them.
- **Scope.** A feature whose code the diff does not touch is not re-checked.
  For a feature whose code changed, the design follows what was built
  ("designy mogą odbiegać od tego co zostało zrobione"), except where that
  would replace a thread's work (next section).
- **Result** is a new entry in Imports with the same page: progress while it
  runs, then Needs you, Built and Missing feature?.
- **Master.** Each feature's result lands on master as it finishes (Kacper:
  "od razu master"), recorded as a merge (DesignMerge) so that open threads
  learn of it through the existing "master changed" banner and Merge history
  lists it.
- (Call) The settings drawer's "Re-import" stays as it is: a full rebuild on a
  thread's branch, for when the setup's own inputs change (a new context, an
  added app repository, another stack), which a resync, looking only at code
  that changed, would never carry to untouched features. Its run is listed in
  Imports too.
- (Call) Baseline for the first resync of an import that recorded no app
  commits (the 2026-11-03 Flosis import did not): each app branch's commit as
  of the time that import read the repositories.

## When an update meets a thread's work

Master can be ahead of the app: a design approved in a thread and merged,
which developers have not built yet, or have built differently. Which one
wins is not the AI's to decide. Kacper: "to pozostaje do decyzji usera AI
powinno pokazać co wchodzi a User powinnien to albo zaakceptować albo
odrzucić". Mockup: [review-card.html](2026-11-04-designs-imports/review-card.html).

- **When it waits.** An update waits for him when it would change or remove
  anything a thread put on master that no accepted update has replaced since:
  in the feature's screens, in shared components or in design-system tokens.
  Everything else lands at once, as before. (Call) When the import cannot tell
  whether something came from a thread, it asks.
- (Call) **Not only resyncs.** A retry, a reply or an added feature that would
  change a thread's work (a shared component, say) waits the same way. The
  first import has no threads' work to replace.
- (Call) **What it proposes.** The AI brings in what developers built and
  keeps what a thread designed that the app does not have yet. For each piece
  of a thread's work the update touches, it says which it found: built as
  designed (nothing changes), built differently (the app's version comes in
  and replaces it) or not built yet (kept as designed).
- **The card.** "Review what comes in", in Needs you: what comes in, what is
  kept and what is replaced, each in plain words with the thread it came
  from, and the proposed screens to open beside master's.
  - **Accept** lands it on master as a merge (DesignMerge), like any other
    landing.
  - **Reject** leaves master as it is; the card moves to the Set aside list,
    saying what was not brought in.
  - **Tell the AI something first…** makes a new proposal with his words
    ("take the filter, keep my card").
- **Nothing undecided reaches master.** The proposal waits on its own branch;
  the rest of the import goes on meanwhile.
- **A Reject keeps protecting.** What the thread put on master is still the
  thread's after a Reject, so the next resync that finds that feature's code
  changed asks again.
- (Call) A proposal still waiting when a newer resync reaches the same
  feature is replaced by the newer one, and its card says so.
- (Call) If master changed the same lines while the proposal waited, Accept
  first brings it up to date from master, as a thread's "Update from master"
  does, and then lands it.

## Landing on master

- (Call) A first import, started from the setup form, still lands on master
  once, at the end, as the setup design has it: Designs opens when master is
  ready, and threads never start on components the run is still changing.
- Everything after it lands on master **as each feature finishes**: a retry,
  a reply that resumes a feature, an added feature, and every feature of a
  resync. Each landing is a merge (DesignMerge), for the banner and Merge
  history. An update that would replace a thread's work waits for his Accept
  instead (see When an update meets a thread's work).
- (Call) A feature waiting for Kacper keeps its partial work on its own branch
  until it finishes; nothing half-built reaches master.

## Today's import

The 2026-11-03 Flosis import becomes the first entry in Imports, with its
5 failed features in Needs you: Task workspace and Jira Tasks board as
Couldn't finish ("the AI's answer could not be read"), Designs, Designs setup
and Profile & my access as Not started ("Claude's session limit ran out at
06:48"). Kacper can retry them as soon as this ships.

## Constraints

- **The server's thread limit.** Hostido's CloudLinux container (lve1025)
  allows about 240 threads in all; during the import the browser (Chromium,
  ~150 threads), Claude and the MCP browser server took ~185 of them, and
  other work failed to start ("can't create Thread: Resource temporarily
  unavailable"; a git command failed the same way). (Call) Only one import or
  import retry runs per server at a time, and the builder should cut
  Chromium's threads (launch flags) and keep other AI jobs from piling on while
  an import's browser is up.
- **Claude's limits.** Imports run on the server's Claude Max login until
  billing moves to keys, so the session limit will be hit again; the pause and
  resume above is the answer, not a cap on the run.
- **Test data stays test data**, as in the setup design: the contexts' test
  accounts, never real data, never changing the test accounts themselves.
- **Deploys** restart Solid Queue and cut an import off; the existing resume
  (Designs::ResumeSetupsJob) must keep working for retries, replies and
  resyncs too.

## Left to the builder

- Data model: whether a retry, a reply and a resync are new runs, new turns or
  states of the existing DesignSetup and DesignSetupFeature records, as long
  as each import keeps its page and its history.
- How the blocker question is returned by the AI and recorded.
- Chromium flags and the way other AI jobs wait for an import's browser.
- Copy of the cards beyond what the table and the mockups say.
- How the import tells what a thread put on master (from the merge history or
  from git, by file or by line), as long as it errs toward asking.
- How the proposed screens are shown beside master's.
