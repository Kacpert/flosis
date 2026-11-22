# Accept in the background (Designs imports)

Kacper, 2026-11-22, on import 4's page: "czy możemy odpalać accept w tle …
tak żeby ktoś mógł szybko zaakceptować zmiany a nie czekał". Approved as
proposed ("ok").

## Why

Accept on a review card (an update that would replace a thread's work)
landed the proposal inside the request: fetch from GitHub, merge, an atomic
push, tidying the branch and publishing master. On import 4 each Accept took
14–19 s (production log, 14:28–15:17), and the first one was clicked twice
because nothing happened for so long. Six cards were still waiting.

## Goals

- Accept answers at once. The card leaves Needs you, and the toast says
  "Accepted · <feature> lands on master in a moment".
- A job lands what was accepted in the background, one at a time per import,
  in the order accepted.
- The page lists LANDING ON MASTER · N above Built and refreshes itself
  until nothing is landing.
- A landing that fails (GitHub refuses the push, or anything else) brings the
  card back to Needs you with the reason; Accept works again.
- When master changed the same lines, it is as before: the import's job
  brings the proposal up to date first, then lands it.
- A double click counts once.
- A landing a deploy cut off is picked up again.

## Non-goals

- Reject stays as it is: no merge and no publish, so it is quicker.
- Making a landing itself faster.

## Approaches

1. **A `landing` status and a job on the default queue, limited to one per
   import (picked).** The click flips review → landing atomically and enqueues
   the job; a second job for the same import waits in SolidQueue without
   holding a thread. The default queue's workers never run design turns, so
   a landing starts within a second even while an import builds.
2. A landing queued on the import's own job (designs queue). It would wait
   behind a running import's unit, for hours.
3. A flag on a card that stays `review`. The card would stay in Needs you,
   and every check of a review card would need the flag.

## Design

- `DesignSetupFeature`: status `landing`. `accept!` flips review → landing
  in one conditional update (`queued_at` = when accepted, `error` cleared)
  and says whether it did.
- `Designs::ImportAcceptJob(setup_id)`: default queue,
  `limits_concurrency to: 1, key: "designs-accept-<setup id>"`. It lands the
  import's landing features oldest-accepted first, each at most once per run.
  - Landed: done, as Accept did before.
  - `Designs::Repo::Conflict`: queued with `accepted` and the import's job
    started, as Accept did before.
  - Anything else: back to review, with the reason in `error`.
- The controller's Accept: `accept!`, then the job, then the toast.
- A review card with an error says the error, then "Accept again, or Reject."
- `Designs::ResumeSetupsJob`, every ten minutes, enqueues the job for an
  import with a feature accepted more than five minutes ago and still
  landing. A landing is safe to run again: a branch already on master lands
  nothing and is marked done.

## Left to the builder

The section's look follows SET ASIDE and the running dot on the same page.
