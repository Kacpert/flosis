# Short links to a task's designs: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A task's designs open from `app.flosis.com/<project>/<KEY>(/wip)(/<context>/<screen>)`, found among the signed-in person's organizations. Every link Flosis writes uses that form, and the canvas can copy one.

**Architecture:**
- `Designs::Publisher#url` writes the short form for a task's key. Master keeps its form.
- A last route sends `/:project/:key(/*path)` to `Designs::PreviewEntriesController#short`. It finds the task among the person's Workshop projects and redirects under a grant, as lasting links do today. The old `:organization/:project/:key/design` route and `#task` go.
- The canvas gets a link template from the controller. JS fills in the screen and state shown.

**Tech Stack:** Rails 8.1, Minitest, Stimulus. The Chromium tests run in `lib/designs_crawler/test` (node --test, Playwright).

**Spec:** `docs/superpowers/specs/2026-11-23-designs-short-links-design.md`

## Global Constraints

- **Key format:** a key is `[A-Z][A-Z0-9_]+-\d+` or `task-\d+`. Route constraints take no anchors; validation uses an anchored copy.
- **Screen paths:**
  - A screen path in a short link is `<context>/<screen>`: two segments, no dot in either, no trailing slash. It maps to `designs/<context>/<screen>.html`.
  - The writer uses the screen form only for `designs/<ctx>/<screen>.html` where neither name has a dot. Anything else goes as an escaped path.
- **Reserved segment:** `wip` right after the key means the thread branch.
- **No backward compatibility:** the old task links go.
- **Copy:** user-facing text is English, as in the app.

## Review Focus

1. Two organizations with the same project label and key: the chooser lists both, and `?org=<label>` opens one.
2. A person who sees the project label in no organization, or the task not at all: 404, never another organization's task.
3. `/wip` on a task with no published thread branch falls back to the normal version, never a 404 when something is published.
4. Escaping: a screen or file with a space or `#` survives the trip, and `designs/a.changes.html` is never taken for a screen.
5. Copy link in a thread with no task in branch mode: no button. In master mode: master's link.

---

### Task 1: Publisher writes short links

**Files:**
- Modify: `app/services/designs/publisher.rb` (`#url`; a `TASK_KEY` constant)
- Test: `test/services/designs/publisher_test.rb`, `test/services/designs/jira_links_test.rb`, `test/services/designs/designs_section_test.rb`, `test/jobs/designs/describe_job_test.rb`, `test/services/task_file_test.rb`

**Interfaces:**
- Produces:
  - `Designs::Publisher::TASK_KEY` (unanchored Regexp, for the route);
  - `Designs::Publisher#url(slot, path = "index.html", ctx: [])` → String. For a task key: `"#{base_url}/#{project_label}/#{key}"` plus `"/<ctx>/<screen>"` or `"/<escaped path>"`, plus `?ctx=`. Master is unchanged. Any other slot raises ArgumentError.

- [ ] Update the URL expectations in the five test files to the short form. Add tests to publisher_test:
  - `url("REC-1", "designs/admin/jobs.html")` == `".../elvium/REC-1/admin/jobs"`;
  - `url("task-551", nil)` == `".../elvium/task-551"`;
  - `url("REC-1", "designs/admin/jobs.changes.html")` stays a path: `".../elvium/REC-1/designs/admin/jobs.changes.html"`;
  - `url("accepted/7", nil)` raises.
- [ ] Run them: they fail with the old URLs.
- [ ] Implement `#url`, and run the five files: green.
- [ ] Commit.

### Task 2: Short links open the task's designs

**Files:**
- Modify: `config/routes.rb` (drop the `:key/design` route; add the last route `get ":project/:key(/*path)" → designs/preview_entries#short`, constraint `key: TASK_KEY`, `format: false`)
- Modify: `app/controllers/designs/preview_entries_controller.rb` (`#short`; drop `#task`; `open_preview(slot, project, page)`)
- Create: `app/views/designs/preview_entries/choose.html.erb`
- Test: `test/controllers/designs/preview_entries_controller_test.rb`

**Interfaces:**
- Consumes: `Designs::Publisher#url` (Task 1).
- Produces: `GET /:project/:key(/*path)`.

- [ ] Rewrite the task-link tests to short links, and add tests for:
  - sign-in first;
  - the branch, else the accepted copy, else the key's slot;
  - `/admin/jobs` → `designs/admin/jobs.html`;
  - `/wip` → the thread branch, even once accepted;
  - `/wip` without a published branch → the normal version;
  - `task-<id>`;
  - a label no visible project has → 404;
  - the task invisible → 404;
  - two organizations → the chooser lists both, with `?org=`;
  - `?org=` opens that one.
- [ ] Run them: they fail with no route.
- [ ] Implement, then run `preview_entries_controller_test`, `previews_controller_test` and `test/controllers/workshop/designs_module_controller_test.rb`: green.
- [ ] Commit.

### Task 3: Copy link in the canvas

**Files:**
- Modify: `app/controllers/workshop/designs_module_controller.rb` (`@link_template`)
- Modify: `app/views/workshop/designs_module/_canvas.html.erb` (the button)
- Modify: `app/javascript/controllers/designs_canvas_controller.js` (`shown`, `copyLink`)
- Test: `test/controllers/workshop/designs_module_controller_test.rb`, `lib/designs_crawler/test/designs_canvas.test.mjs`

**Interfaces:**
- **`@link_template`:** a URL with `{context}` and `{screen}`. It is the URL of the screen as rendered for `context="{context}"`, `screen="{screen}"`, with the braces unescaped, or nil.
  - A live thread with a task, in branch or changes mode: `url(key, nil) + "/wip/{context}/{screen}"`.
  - A finished thread with a task: `url(key, nil) + "/{context}/{screen}"`.
  - Master mode: `url(MASTER, "designs/{context}/{screen}.html")`, built with placeholders.
  - Otherwise nil.
- **JS:** `copyLink` puts in the context and screen the frame shows (from `flosis:screen`) and `#<state>` when the state is not the default. It copies with `navigator.clipboard.writeText` and toasts "Link copied · <link>".

- [ ] Add a view test (template on a live task thread with `/wip/`; no button for a thread with no task in branch mode) and a Chromium test (screen admin/billing in state paused → clipboard holds `<template filled>#paused`). Run them: they fail.
- [ ] Implement, and run both: green. Run `npm test` in `lib/designs_crawler`: green.
- [ ] Commit.

### Finish

- [ ] Full suite on a private database; only the 5 known date failures may fail.
- [ ] Final review.
- [ ] Deploy, with a postcheck that `/flosis/task-551` resolves its route. Check that curl of a short link redirects to sign-in.
- [ ] Merge onto main, and update memory `project_designs_short_links`.
