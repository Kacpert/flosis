# Accept in the background Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept on an import's review card answers at once, and a job lands the accepted proposals on master in the background.

**Architecture:** A new feature status `landing`. Accept flips review → landing atomically and enqueues `Designs::ImportAcceptJob` on the default queue, limited to one per import. The job lands the import's landing features in the order accepted with the existing `Designs::ImportLanding`. The import's page lists them under LANDING ON MASTER and refreshes until they land; `Designs::ResumeSetupsJob` re-enqueues a landing whose job was lost.

**Tech Stack:** Rails 8.1, Solid Queue 1.4 (`limits_concurrency`), Minitest integration tests with a local bare remote (DesignRepoTestHelper).

**Spec:** `docs/superpowers/specs/2026-11-22-designs-accept-in-background-design.md`

## Global Constraints

- Toast: `Accepted · <feature name> lands on master in a moment`.
- Section heading: `LANDING ON MASTER · <n>`; a row says `<name> · accepted HH:MM`.
- A failed landing's card text: `<error> Accept again, or Reject.`; a generic error reads `Couldn't land on master: <first line>.`
- The job runs on the `default` queue, with the concurrency key `designs-accept-<setup id>`.
- A landing is stale after 5 minutes (`Designs::ImportAcceptJob::STALE`).
- Reject is unchanged.
- Tests run with `PARALLEL_WORKERS=1`; SQL stays portable (MariaDB in production).

## Review Focus

- A landing that a deploy cut off after its push runs again: it is marked done, and master is not merged twice (Task 3 test).
- Accept, then Reject or words on the same card before the page reloads: nothing happens, and the landing goes on (Task 1 test).
- An import still building when Accept is clicked: the landing runs on the default queue, never behind the import's designs-queue unit (Task 1 asserts the queue).
- Two proposals accepted in a row land one after the other, in the order accepted (Task 1 test).

---

### Task 1: Accept lands in the background

**Files:**
- Modify: `app/models/design_setup_feature.rb` (STATUSES, `accept!`)
- Create: `app/jobs/designs/import_accept_job.rb`
- Modify: `app/controllers/workshop/design_import_features_controller.rb` (`accept`)
- Modify: `app/helpers/design_imports_helper.rb` (`import_card_text`, :review)
- Test: `test/jobs/designs/import_reviews_test.rb`

**Interfaces:**
- Produces: status `"landing"`; `DesignSetupFeature#accept! -> Boolean` (review → landing, `queued_at` now, `error` nil; true only for the call that flipped it); `Designs::ImportAcceptJob.perform_later(setup_id)`.

- [ ] **Step 1: Write the failing tests** in `import_reviews_test.rb`. Replace "Accept lands it" with "Accept answers at once, and the landing goes on in the background":
  - `assert_enqueued_with(job: Designs::ImportAcceptJob, args: [ @import.id ])` around the post;
  - toast `"Accepted · Bug Reporting lands on master in a moment"`;
  - status `"landing"` and the remote master unchanged;
  - after `perform_enqueued_jobs(only: Designs::ImportAcceptJob)`: `["done", nil, true]` for status, branch and `review["accepted"]`, merges `%w[manual import]`, and the app's card on master;
  - `assert_equal "default", Designs::ImportAcceptJob.new.queue_name`.

  Add:
  - "a second click on Accept, or Reject after it, changes nothing": two accepts and then a reject give one enqueued ImportAcceptJob, the status is still `"landing"`, and the remote branch is still there.
  - "proposals accepted one after another land in that order": a second review feature "Settings" (key `settings`) with its own branch `wip/import-<id>-settings` adds `designs/admin/settings.html` and is pushed. Accept Settings, then Bug Reporting, and perform the jobs: both are done, and the merge titles are `["Bug card v2", "Settings", "Bug Reporting"]`.
  - "a landing GitHub refuses brings the card back with the reason": a remote `hooks/pre-receive` that exits 1. After the job, the problem is `:review` and the error matches `/\ACouldn't land on master: .+\.\z/`. The page shows `"#{error} Accept again, or Reject."` and the Accept form.
  - Adapt "Accept after master moved the same lines…": perform ImportAcceptJob first, then expect `["todo", true]` and the SetupRunJob part as before.
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/jobs/designs/import_reviews_test.rb`. Expected: the new and changed tests FAIL, because `Designs::ImportAcceptJob` is an uninitialized constant.
- [ ] **Step 3: Implement.**
  - Add `landing` to STATUSES.
  - `accept!` is one `update_all` guarded by `status: "review"`, then a reload.
  - The job: `queue_as :default`, `limits_concurrency to: 1, key: ->(setup_id) { "designs-accept-#{setup_id}" }, duration: 10.minutes`. `perform(setup_id)` loops over the landing features by `queued_at, id`, each at most once per run (a `tried` list), and `land`s each:
    - success → done, as the old controller did, with `error: nil`;
    - `Designs::Repo::Conflict` → `queue!(fresh: false)` plus `accepted`, then `start_work!`;
    - any other StandardError → logged, then status `review` with `error` (NotLanded's own message, else the generic copy).
  - The controller: `accept!`, `perform_later` and the toast.
  - The helper: a review card with an error shows the failed-landing copy.
- [ ] **Step 4: Run** the same file. Expected: all PASS.
- [ ] **Step 5: Commit** `feat: Accept answers at once and a job lands the proposal on master, one at a time in the order accepted`.

### Task 2: LANDING ON MASTER on the import's page

**Files:**
- Modify: `app/views/workshop/design_imports/_import.html.erb`
- Test: `test/controllers/workshop/design_imports_pages_test.rb`

**Interfaces:**
- Consumes: status `"landing"` and `queued_at` from Task 1.

- [ ] **Step 1: Write the failing test** "an accepted proposal waits under Landing on master, and the page refreshes until it lands": `first_import` with `["Bug Reporting", "landing", { queued_at: Time.zone.local(2026, 11, 22, 15, 21) }]` and `["Settings", "done"]`. On the page:
  - `[data-import-landing=bug-reporting]` has text matching `/Bug Reporting\s*· accepted 15:21/`;
  - the body includes `LANDING ON MASTER · 1`;
  - there is no `[data-import-card=bug-reporting]`;
  - `[data-controller=designs-refresh]` is present.
- [ ] **Step 2: Run** `PARALLEL_WORKERS=1 bin/rails test test/controllers/workshop/design_imports_pages_test.rb`. Expected: FAIL, no `data-import-landing`.
- [ ] **Step 3: Implement.** The section goes just above Built, styled like SET ASIDE, with the blinking `--ai` dot from "Running in the background". The refresh condition adds `landing.any?`.
- [ ] **Step 4: Run** the same file. Expected: all PASS.
- [ ] **Step 5: Commit** `feat: an import's page lists what is landing on master and refreshes until it lands`.

### Task 3: A lost landing is picked up again

**Files:**
- Modify: `app/jobs/designs/import_accept_job.rb` (`self.resume!`, `STALE`)
- Modify: `app/jobs/designs/resume_setups_job.rb`
- Test: `test/jobs/designs/resume_setups_job_test.rb`, `test/jobs/designs/import_reviews_test.rb`

**Interfaces:**
- Produces: `Designs::ImportAcceptJob::STALE = 5.minutes`. `Designs::ImportAcceptJob.resume!` enqueues once per import that has a landing feature with `queued_at` older than STALE.

- [ ] **Step 1: Write the failing tests.**
  - In `resume_setups_job_test.rb`, "a landing whose job was lost is landed again, a fresh one is left to its job": imports with a landing feature at 6 and at 1 minute ago. After `ResumeSetupsJob.perform_now`, the only ImportAcceptJob arguments are `[[stale.id]]`.
  - In `import_reviews_test.rb`, "a landing run again after its push is done, and master is merged once": land the feature with `Designs::ImportLanding.new(@feature).land!(accepted: true)`, set it back to `landing`, then perform ImportAcceptJob. It is done, and the merges are still `%w[manual import]`.
- [ ] **Step 2: Run both files.** Expected: the resume test FAILs because no job is enqueued. The re-run test may already pass: `land!` lands nothing for a branch already on master, so it pins the behaviour.
- [ ] **Step 3: Implement** `resume!` and call it at the end of `ResumeSetupsJob#perform`.
- [ ] **Step 4: Run both files.** Expected: all PASS.
- [ ] **Step 5: Commit** `feat: a landing whose job a deploy cut off is picked up again`.
