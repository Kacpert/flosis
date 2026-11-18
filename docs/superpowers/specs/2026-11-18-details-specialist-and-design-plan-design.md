# Details as a specialist, and Design that starts with a plan

**Date:** 2026-11-18
**Status:** Draft for Kacper's approval (builder check done)

## Why

Kacper, on SCRUM-70 ("AI usage and cost per organization"): the Details AI's
descriptions are "too much soap, too little meat". Background and User story
say the same thing twice. The AI asks about business rules but never about
where things show on screen. So when he clicks Design, the designer AI guesses.
On SCRUM-70 it put a price on every chat message and no totals anywhere. He
waits ten minutes and then has to fix most of it.

He rewrote the SCRUM-70 description himself. It is the target for every
description (see "The description" below). Compared with the AI's version
(v1), his:

- opens with three sentences (what is wrong, what we do, what comes next), not
  a Background and then a User story;
- is laid out by where things show (on the item itself, in each area's tab,
  Settings → Consumption, the profile), with formats ("$12 ($3.23 this month)")
  and visual weight ("small, muted text");
- states decisions as rules with an example ("cost 10 USD, margin 30% → price
  13 USD"), not formulas or source-of-truth discussions;
- gives every open question a proposal ("Fallback: admin enters prices by
  hand");
- has no section for the developer (no file paths).

Kacper's rules for the conversation (2026-11-18):

- "This whole step makes sure we have everything for implementation, but we
  come in as a specialist. We don't ask about everything: we describe how best
  to solve it and what the standards are."
- "Messages must be short. People read them, and people read slowly."
- No switch between "for a designer" and "for the AI". No extra step between
  Details and Design either: Design itself starts differently.
- At Design: "the AI first makes sure in the chat that its assumptions are right
  and it knows what to do". "If it has no doubts, it says so and designs."

## Goals

1. The Details chat behaves like a specialist. It reads the app's code (the
   app's own views are its screens, as today), proposes the standard
   solution, and asks only what a standard cannot settle. Its messages are
   short.
2. Before it drafts, it has everything an implementer needs, placement on
   screen included.
3. Descriptions follow Kacper's format: short, concrete, no repetition.
4. A design thread started from a task first posts a short plan. It asks only
   what it cannot decide. With no doubts, it says so and designs at once.

## Non-goals

- The Briefing chat (BriefChatSessionsController) stays as it is.
- No "designer / AI" switch.
- Descriptions already written keep their format. Only new drafts change.
- Threads started from a typed request (not from a task) start as today.

## Anti-goals (it fails even if it works)

- Messages longer than a few sentences, or several questions in one message.
- Open questions where a standard answer exists ("Where should it show?"
  instead of "I'd put it in the chat header, muted. OK?").
- A plan step that feels like a gate: a form, a wizard, a wait when nothing is
  unclear.
- A description that repeats itself, or that a designer still has to guess
  placement from.

## Part 1: the Details chat (ChatSessionsController#build_initial_prompt)

One prompt, changed for everyone who uses it. It serves Workshop's Details
Gathering and the Jira Tasks board's "Chat with AI" / "AI refined ticket
description". Kacper (2026-11-18): the board view "was added only for
debugging; there shouldn't even be AI there, and in the end it can be
hidden". So the prompt does not branch on where it runs. Hiding the board's AI
or the board itself is a separate, later change.

The chat keeps reading only what it reads today (the app checkout,
attachments, Figma). It is not given the design repo: the chat is open to
people without Designs access, and Part 2's plan turn reconciles placement
with the design repo's screens anyway.

Keep these as they are: Step 0 (briefed and unbriefed variants), the code
investigation step, product language in the chat (no file paths or code), the
`<draft>` mechanics and the panel note, drafting the moment the picture is
complete (fa269da), and revisions as new `<draft>` blocks.

Change:

**Role.** A specialist who has done this before. They propose how to solve it
and say what the standard is ("Costs like this usually sit in the header,
muted, so they don't compete with the content"). They ask only about decisions
a standard cannot settle: business rules, numbers only the owner knows, and
trade-offs where both options are reasonable.

**Messages.** At most three short sentences. One decision per message, put as
a proposal to confirm ("I'd show X there, as Y. OK?"), not an open question.
No lists of questions.

**Covered before drafting.** For every piece of information or control the
ticket adds:

- where it shows (screen, tab, spot);
- who sees it;
- its default (shown or hidden, on or off);
- one item or a total, and for which period;
- its format, with an example;
- empty and error states.

The AI settles these from standards wherever it can, and confirms only what it
cannot. What nobody confirmed goes into the description as the standard
choice, not as an open question.

**The description (the `<draft>` template).** Replace Background, User story,
Requirements, Implementation pointers and Integration with:

```
<2–3 sentences, no heading: what is wrong today, what this ticket does, what comes next>

## <Feature or place on screen>      (one section each, e.g. "Plans (Flosis admin)",
- what it does, where, who sees it,   "Cost of a single item", "Settings → Consumption (admins only)")
  defaults, formats with an example

## Rules
- what holds across sections, with an example wherever a number is involved

## Out of scope
<one line>

## Acceptance criteria
- [ ] ...

## Open questions          (only if any; each with "Proposal: ...")
```

There is no title line (the task has a name), no user story and no file
paths. A section never repeats another one. External dependencies (APIs,
credentials) go in a section of their own only when the ticket has them.

## Part 2: Design starts with a plan (Designs)

Applies to a thread started from a task (Designs::Threads.start_from_task!,
the Design button). Its first turn is a **plan turn** in place of today's
hidden "Design this task" request:

- New turn kind `plan`. It gets the same message as a thread turn (task,
  current description, repo map), but read-only tools (Read, Glob, Grep). It
  cannot change a file.
- It replies in the existing blocks:
  - `<summary>`: the plan, at most about five short lines, saying what it will
    design and where (screen and spot), reusing existing screens wherever they
    cover it.
  - `<missing>`: one block per question it cannot settle, each with its
    proposal ("Where should a conversation's total show? Proposal: in its
    header, muted, as $12 ($3.23 this month)").
  - With nothing missing, the summary ends by saying there are no doubts.
- **No `<missing>`:** Flosis queues the design turn at once, in the same Claude
  session, with a hidden request ("No doubts: design it as planned"). The
  person sees the plan, then the live design turn.
- **`<missing>` present:** the thread waits. The person answers in the chat
  (an ordinary message, which starts a design turn), or clicks a "Design with
  these proposals" button under the plan. The button sends a hidden request
  that accepts every proposal and starts the design turn.
- The plan turn must be quick (well under a minute or two). It gets a small
  budget and a short timeout, and runs at a lower effort than design turns.
- While it runs, the live block says "Planning". A failed plan turn gets Try
  again like any turn.
- What the chat settles stays in the design (the screens record it). The task
  description is not rewritten.

The design turn's own rules are unchanged (screens only, then components
before merge).

## Coordination

Another Gold session (gold-83, formerly gold-14) has edited the Details prompt
(fa269da). Tell it before pushing changes to ChatSessionsController.

## Left to the builder

The exact prompt wording; whether the Details prompt embeds a short example
drawn from Kacper's SCRUM-70 description; the plan turn's effort level, budget
and timeout; the button label and where it sits; the hidden requests' wording.
