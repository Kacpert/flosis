# Short links to a task's designs (2026-11-23)

## Why

Kacper (2026-11-23): the links to designs in a ticket should be short, "po prostu numer ticketa a nasz portal sam wie która wersja jest aktualna". A `wip` link should show the current work even if it is not yet accepted. Someone working on a task with nothing accepted can send a link so another person sees it.

Today's links (`/<organization>/<project>/<KEY>/design/designs/<context>/<screen>.html`) are long. They also break when the organization or the project is renamed.

## Decided (Kacper)

- **The format:** `app.flosis.com/<project>/<KEY>`.
  - `<project>` is the project's link label (`Designs::Publisher.label`).
  - `<KEY>` is the Jira key, or `task-<id>` for a task with none.
  - The organization is **not** in the link.
- **Finding the project:** Flosis looks for the project among the projects the signed-in person's organizations show them. The same project name and key in two organizations is rare. Then a short list asks which one.
- **No backward compatibility:** only one task has links yet. The old task route goes.
- **The domain:** the organization will probably move into the domain later (instead of `app.`). That comes later, and the links are to be revisited then (memory `project_designs_short_links`).

## The links

| Link | Opens |
|---|---|
| `/<project>/<KEY>` | The latest accepted version, else the work in progress (today's rule, `task_slot`). Opens on the list of what changed when there is one. |
| `/<project>/<KEY>/wip` | Always the task's thread branch, the current work, when it is published. Otherwise the same as above. |
| `/<project>/<KEY>(/wip)/<context>/<screen>` | That screen: `designs/<context>/<screen>.html`. |
| `/<project>/<KEY>(/wip)/<any other path>` | That file of the version, as today's links allow. |

- `#state` and `?ctx=` go along, as today.
- `wip` is reserved as the first segment after the key.
- A screen path is exactly two segments with no dot in either and no trailing slash. Anything else is a path inside the version.

## Constraints

- **Sign-in:** every link needs sign-in and a project the Workshop shows the person, as today. They are then sent on under a short-lived grant (`Designs::PreviewsController`), which is unchanged.
- **The route:** it comes last. Its key must look like a ticket key (`[A-Z][A-Z0-9_]+-\d+` or `task-\d+`), so no page of the app is taken for one. A project whose label is an app section with ids (`projects`, `clients`, `tags`, `passwords`, …) gets no working short link. That is an accepted risk.
- **Master:** the project's own designs (master) keep their link, `/<organization>/<project>/design/…`. It is not a ticket link.
- **One place makes the links:** `Designs::Publisher#url`. So the Designs section of a description, Jira's web links, the task's file and the "Open designs" buttons all change at once.

## Approaches considered

1. **`/d/<KEY>`, searched among every project the person sees:** the shortest. Ticket keys repeat across clients (`SCRUM-…`), though, so it needs a chooser often for anyone who sees several clients. Rejected for `/<project>/<KEY>`.
2. **`/<organization>/<KEY>`:** unique, but it depends on the organization's name. Rejected by Kacper.
3. **`/<project>/<KEY>`, searched among the person's organizations:** chosen.

## Copy link (my call)

The canvas bar gets "Copy link", beside "Open in new tab". It copies the short link to the screen and state being looked at:

| Where | Link copied |
|---|---|
| A live thread with a task | `/wip/` |
| A finished thread | The plain task link |
| Master | Master's link |
| A thread with no task, in branch mode | No button |

It is the link to send someone.

## Left to the builder

- The chooser's look: a plain list in the app's layout.
- The order of the matches: by organization, then project.
