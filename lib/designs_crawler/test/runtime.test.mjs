// The design repo's runtime (lib/designs_template/runtime/flosis.js) in
// Chromium. A page stays hidden until its kit has styled it, so clicking
// through the designs never shows unstyled text first; a kit that never
// styles it still lets the page show after a while.
import { test, before, after } from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs/promises"
import http from "node:http"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { chromium } from "playwright"
import { CHROMIUM_ARGS } from "../browser_lib.mjs"

const here = path.dirname(fileURLToPath(import.meta.url))
const runtime = path.join(here, "../../designs_template/runtime/flosis.js")
const TYPES = { ".js": "text/javascript", ".json": "application/json", ".css": "text/css", ".html": "text/html" }
let server, base, browser, tmp, canLaunch = true

// Tailwind's browser build writes its output, banner first, into a <style> a
// moment after kit.js has loaded; this kit does the same, 400 ms late.
const KITS = {
  styled: `setTimeout(() => { const s = document.createElement("style"); s.textContent = "/*! tailwindcss v4.2.1 | MIT License | https://tailwindcss.com */ h1{color:rgb(1, 2, 3)}"; document.head.append(s) }, 400)`,
  silent: "/* a kit that never styles the page */"
}

before(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), "flosis-runtime-"))
  for (const [name, kit] of Object.entries(KITS)) {
    const repo = path.join(tmp, name)
    await fs.mkdir(path.join(repo, "runtime"), { recursive: true })
    await fs.mkdir(path.join(repo, "design-system"), { recursive: true })
    await fs.mkdir(path.join(repo, "designs/admin"), { recursive: true })
    await fs.copyFile(runtime, path.join(repo, "runtime/flosis.js"))
    await fs.writeFile(path.join(repo, "runtime/config.json"), JSON.stringify({ kit: "tailwind4" }))
    await fs.writeFile(path.join(repo, "runtime/kit.js"), kit)
    await fs.writeFile(path.join(repo, "design-system/theme.css"), "@theme { --color-brand: #5b5bd6; }")
    await fs.writeFile(path.join(repo, "designs/admin/bugs.html"),
      `<!doctype html><html><head><script src="../../runtime/flosis.js"></script></head><body><h1>Bug Reporting</h1></body></html>`)
  }
  server = http.createServer(async (req, res) => {
    try {
      const file = path.join(tmp, decodeURIComponent(new URL(req.url, "http://localhost").pathname))
      const body = await fs.readFile(file)
      res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "text/plain" }).end(body)
    } catch {
      res.writeHead(404).end()
    }
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  base = `http://127.0.0.1:${server.address().port}`
  try {
    browser = await chromium.launch()
  } catch {
    canLaunch = false
  }
})

after(async () => {
  await browser?.close()
  server?.close()
  await fs.rm(tmp, { recursive: true, force: true })
})

// What the page looks like the moment it first becomes visible.
const firstShown = () => new Promise((resolve) => {
  const check = () => getComputedStyle(document.documentElement).visibility === "visible"
    ? resolve(getComputedStyle(document.querySelector("h1")).color)
    : setTimeout(check, 5)
  check()
})

test("a page is hidden until its kit has styled it, and shown styled", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const page = await browser.newPage()
  await page.goto(`${base}/styled/designs/admin/bugs.html`, { waitUntil: "domcontentloaded" })
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).visibility), "hidden")
  assert.equal(await page.evaluate(firstShown), "rgb(1, 2, 3)")
  await page.close()
})

test("a page whose kit never styles it is still shown", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const page = await browser.newPage()
  await page.goto(`${base}/silent/designs/admin/bugs.html`)
  await page.waitForFunction(() => getComputedStyle(document.documentElement).visibility === "visible", null, { timeout: 6000 })
  await page.close()
})

test("Chromium started as the setup starts it still renders and shoots a page in each context", async (t) => {
  let lean
  try {
    lean = await chromium.launch({ args: CHROMIUM_ARGS })
  } catch {
    return t.skip("Chromium cannot start here")
  }
  const titles = []
  for (const name of [ "styled", "silent" ]) {
    const page = await (await lean.newContext()).newPage()
    await page.goto(`${base}/${name}/designs/admin/bugs.html`)
    titles.push(await page.locator("h1").textContent())
    assert.ok((await page.screenshot()).length > 1000, "a screenshot without the GPU")
  }
  await lean.close()
  assert.deepEqual(titles, [ "Bug Reporting", "Bug Reporting" ])
})

// A tab of its own as a person has it: Playwright's browser says it is driven
// by a test (navigator.webdriver), and the runtime shows such a browser the
// page alone.
const ownTab = async () => {
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } })
  await context.addInitScript(() => Object.defineProperty(Navigator.prototype, "webdriver", { get: () => false }))
  return context
}

// Kacper (2026-11-19): a preview opened in a tab of its own had no way to the
// other screens. Outside the Designs canvas a screen gets a floating panel
// (2026-11-22) that steps through the screens the thread changed
// (__flosis/changes.json) and lists them; inside the canvas, which has its
// own, there is none.
test("opened in a tab of its own, a changed screen steps to the next change; inside the canvas it has no panel", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const repo = path.join(tmp, "styled")
  await fs.mkdir(path.join(repo, "__flosis"), { recursive: true })
  for (const [id, title] of [ [ "bugs", "Bug Reporting" ], [ "consumption", "Consumption" ] ]) {
    await fs.writeFile(path.join(repo, `designs/admin/${id}.changes.html`),
      `<!doctype html><html><head><title>${title}</title><script src="../../runtime/flosis.js"></script></head><body><h1>${title}</h1></body></html>`)
  }
  await fs.writeFile(path.join(repo, "__flosis/screens.json"), JSON.stringify({
    contexts: [ { id: "admin", name: "Admin" } ],
    screens: [ { id: "bugs", context: "admin", name: "Bug Reporting", path: "designs/admin/bugs.html" },
               { id: "consumption", context: "admin", name: "Consumption", path: "designs/admin/consumption.html" } ]
  }))
  await fs.writeFile(path.join(repo, "__flosis/changes.json"), JSON.stringify({ own: [ [ "admin", "bugs", "updated" ], [ "admin", "consumption", "new" ] ], through: {} }))
  await fs.writeFile(path.join(repo, "canvas.html"), `<!doctype html><html><body><iframe src="designs/admin/bugs.changes.html"></iframe></body></html>`)

  const context = await ownTab()
  const page = await context.newPage()
  await page.goto(`${base}/styled/designs/admin/bugs.changes.html`)
  await page.evaluate(() => window.Flosis.ready)
  const bar = await page.textContent("[data-flosis-dock] [data-flosis-nav]")
  assert.match(bar, /Bug Reporting/)
  assert.match(bar, /1 \/ 2/)
  assert.equal(new URL(await page.getAttribute("[data-flosis-nav] a[data-flosis-next]", "href")).pathname,
               "/styled/designs/admin/consumption.changes.html")
  await page.click("[data-flosis-nav] button[data-flosis-list]")
  assert.deepEqual(await page.$$eval("[data-flosis-nav-list] a", (links) => links.map((link) => link.textContent.trim())).then((names) => names.slice(0, 2)),
                   [ "Bug Reporting", "Consumption" ])
  await page.fill("[data-flosis-nav-list] input", "cons")
  assert.deepEqual(await page.$$eval("[data-flosis-nav-list] a", (links) => links.filter((link) => link.offsetParent).map((link) => link.textContent.trim())),
                   [ "Consumption", "Consumption" ])

  await page.goto(`${base}/styled/canvas.html`)
  const frame = page.frames().find((f) => f.url().endsWith("bugs.changes.html"))
  await frame.evaluate(() => window.Flosis.ready)
  assert.equal(await frame.$("[data-flosis-dock]"), null)
  await context.close()
})

// Kacper (2026-11-22): one file per page of the app, with its states inside
// it, so that a change is made once. <nav data-states> lists them, the hash
// picks one, and data-show-in, data-hide-in and data-open-in say what each
// state shows.
const writeStates = async (repo) => {
  await fs.mkdir(path.join(repo, "components/note"), { recursive: true })
  await fs.writeFile(path.join(repo, "components/note/note.html"), `<!-- A note --><p class="note">{{text}}</p>`)
  await fs.writeFile(path.join(repo, "designs/admin/usage.html"), `<!doctype html><html><head><title>Consumption</title>
    <script src="../../runtime/flosis.js"></script></head><body>
    <nav data-states><a href="#">This month</a><a href="#over-limit">Over the limit</a><a href="#reset">Reset</a></nav>
    <h1>Consumption</h1>
    <p id="limit" data-show-in="over-limit">Over the limit</p>
    <p id="figure" data-hide-in="over-limit">$12</p>
    <x-include src="components/note/note.html" text="Closed month" data-show-in="over-limit reset"></x-include>
    <div id="dialog" class="hidden" data-open-in="reset">Reset?</div>
    <a id="anchor" href="#figure">Figure</a>
    <script>window.Flosis.ready.then(() => { window.heard = []; document.addEventListener("flosis:state", (e) => window.heard.push(e.detail.state)) })</script>
    </body></html>`)
}
const seen = (page) => page.evaluate(() => ({
  state: window.Flosis.state,
  nav: document.querySelector("nav[data-states]").hidden,
  limit: !document.getElementById("limit").hidden,
  figure: !document.getElementById("figure").hidden,
  note: !document.querySelector(".note").hidden,
  dialog: !document.getElementById("dialog").classList.contains("hidden")
}))

test("a screen's hash picks its state: each element shows, hides or opens in it, and the page's script hears of it", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  await writeStates(path.join(tmp, "styled"))
  const page = await browser.newPage()
  await page.goto(`${base}/styled/designs/admin/usage.html`)
  await page.evaluate(() => window.Flosis.ready)
  assert.deepEqual(await seen(page), { state: "default", nav: true, limit: false, figure: true, note: false, dialog: false })

  await page.goto(`${base}/styled/designs/admin/usage.html#over-limit`)
  await page.waitForFunction(() => window.Flosis.state === "over-limit")
  assert.deepEqual(await seen(page), { state: "over-limit", nav: true, limit: true, figure: false, note: true, dialog: false })

  await page.goto(`${base}/styled/designs/admin/usage.html#reset`)
  await page.waitForFunction(() => window.Flosis.state === "reset")
  assert.deepEqual(await seen(page), { state: "reset", nav: true, limit: false, figure: true, note: true, dialog: true })

  // An anchor into the page is not a state: the state stays.
  await page.click("#anchor")
  await page.waitForFunction(() => location.hash === "#figure")
  assert.equal(await page.evaluate(() => window.Flosis.state), "reset")

  // Left, the state closes what it opened.
  await page.goto(`${base}/styled/designs/admin/usage.html#`)
  await page.waitForFunction(() => window.Flosis.state === "default")
  assert.deepEqual(await seen(page), { state: "default", nav: true, limit: false, figure: true, note: false, dialog: false })
  assert.deepEqual(await page.evaluate(() => window.heard), [ "over-limit", "reset", "default" ])

  // Opened straight at a state, the page is in it from its first paint.
  const direct = await browser.newPage()
  await direct.goto(`${base}/styled/designs/admin/usage.html#over-limit`, { waitUntil: "domcontentloaded" })
  assert.equal(await direct.evaluate(() => new Promise((resolve) => {
    const check = () => getComputedStyle(document.documentElement).visibility === "visible"
      ? resolve(!document.getElementById("limit").hidden)
      : setTimeout(check, 5)
    check()
  })), true)
  await direct.close()
  await page.close()
})

// A dialog shown only with its thread and opened in one of that thread's
// states: leaving for another thread hides it, whatever the opening left.
test("an element both shown in some states and opened in one is hidden again in the others", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const repo = path.join(tmp, "styled")
  await fs.writeFile(path.join(repo, "designs/admin/thread.html"), `<!doctype html><html><head><title>Thread</title>
    <script src="../../runtime/flosis.js"></script></head><body>
    <nav data-states><a href="#">Thread</a><a href="#accept">Accept</a><a href="#other">Another thread</a></nav>
    <div id="accept" class="hidden" data-show-in="default accept" data-open-in="accept">Accept?</div>
    </body></html>`)
  const page = await browser.newPage()
  const accept = () => page.evaluate(() => {
    const element = document.getElementById("accept")
    return { hidden: element.hidden, closed: element.classList.contains("hidden") }
  })
  await page.goto(`${base}/styled/designs/admin/thread.html#accept`)
  await page.evaluate(() => window.Flosis.ready)
  assert.deepEqual(await accept(), { hidden: false, closed: false })
  await page.goto(`${base}/styled/designs/admin/thread.html#other`)
  await page.waitForFunction(() => window.Flosis.state === "other")
  assert.deepEqual(await accept(), { hidden: true, closed: true })
  await page.goto(`${base}/styled/designs/admin/thread.html#`)
  await page.waitForFunction(() => window.Flosis.state === "default")
  assert.deepEqual(await accept(), { hidden: false, closed: true })
  await page.close()
})

test("the floating panel switches a screen's states; a test browser gets no panel", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  await writeStates(path.join(tmp, "styled"))
  const context = await ownTab()
  const page = await context.newPage()
  await page.goto(`${base}/styled/designs/admin/usage.html#reset`)
  await page.evaluate(() => window.Flosis.ready)
  const select = "[data-flosis-dock] select[data-flosis-state-select]"
  assert.deepEqual(await page.$$eval(`${select} option`, (options) => options.map((o) => [ o.value, o.textContent, o.selected ])),
                   [ [ "default", "This month", false ], [ "over-limit", "Over the limit", false ], [ "reset", "Reset", true ] ])
  await page.selectOption(select, "over-limit")
  await page.waitForFunction(() => window.Flosis.state === "over-limit")
  assert.equal(await page.evaluate(() => location.hash), "#over-limit")
  await page.goto(`${base}/styled/designs/admin/usage.html#`)
  await page.waitForFunction(() => window.Flosis.state === "default")
  assert.equal(await page.$eval(select, (s) => s.value), "default")
  await context.close()

  const automated = await browser.newPage()
  await automated.goto(`${base}/styled/designs/admin/usage.html#reset`)
  await automated.evaluate(() => window.Flosis.ready)
  assert.equal(await automated.$("[data-flosis-dock]"), null)
  await automated.close()
})

// Kacper (2026-11-22): the panel floats. Unfolded, it drags by its grip (and
// sits at the margin when dropped against an edge); folded, it is a small dot
// that drags anywhere and unfolds away from the nearest edges, to the right of
// a dot on the left and to the left of one on the right. Where it is and
// whether it is folded carry on to the next screen in the tab.
test("the floating panel folds to a dot that drags anywhere and unfolds away from its edge", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const context = await ownTab()
  const page = await context.newPage()
  await page.goto(`${base}/styled/designs/admin/bugs.changes.html`)
  await page.evaluate(() => window.Flosis.ready)
  const rect = (selector) => page.$eval(selector, (element) => {
    const r = element.getBoundingClientRect()
    return { left: Math.round(r.left), top: Math.round(r.top), right: Math.round(r.right), bottom: Math.round(r.bottom) }
  })
  const drag = async (selector, dx, dy) => {
    const r = await rect(selector)
    const x = (r.left + r.right) / 2, y = (r.top + r.bottom) / 2
    await page.mouse.move(x, y)
    await page.mouse.down()
    await page.mouse.move(x + dx, y + dy, { steps: 8 })
    await page.mouse.up()
  }

  // Its whole background drags, its name too; its controls do not.
  const panel = await rect("[data-flosis-dock]")
  await drag("[data-flosis-dock] [data-flosis-name]", -200, -100)
  const dragged = await rect("[data-flosis-dock]")
  assert.deepEqual([ dragged.left, dragged.top ], [ panel.left - 200, panel.top - 100 ])
  await drag("[data-flosis-dock] [data-flosis-list]", -50, -50)
  assert.deepEqual(await rect("[data-flosis-dock]"), dragged, "a press on a control does not drag")
  await page.keyboard.press("Escape")
  await drag("[data-flosis-grip]", 4 - dragged.left, 4 - dragged.top)
  assert.deepEqual(await rect("[data-flosis-dock]").then((r) => [ r.left, r.top ]), [ 12, 12 ])

  await page.click("[data-flosis-dock] button[data-flosis-fold]")
  const dot = await rect("[data-flosis-dock]")
  assert.deepEqual([ dot.left, dot.top ], [ 12, 12 ])
  assert.ok(dot.right - dot.left <= 32, "a small dot")
  assert.equal(await page.isVisible("[data-flosis-dock] [data-flosis-nav]"), false)

  await page.goto(`${base}/styled/designs/admin/consumption.changes.html`)
  await page.evaluate(() => window.Flosis.ready)
  assert.deepEqual(await rect("[data-flosis-dock]"), dot)

  await drag("[data-flosis-dock] [data-flosis-unfold]", 900, 300)
  const moved = await rect("[data-flosis-dock]")
  assert.deepEqual([ moved.left, moved.top ], [ dot.left + 900, dot.top + 300 ])
  assert.equal(await page.isVisible("[data-flosis-dock] [data-flosis-nav]"), false, "a drag does not unfold it")

  await page.click("[data-flosis-dock] [data-flosis-unfold]")
  assert.equal(await page.isVisible("[data-flosis-dock] [data-flosis-nav]"), true)
  const unfolded = await rect("[data-flosis-dock]")
  assert.deepEqual([ unfolded.right, unfolded.top ], [ moved.right, moved.top ], "on the right half it unfolds to the left")
  assert.ok(unfolded.left < moved.left)
  await context.close()
})

// Kacper (2026-11-22): besides screens and states, the panel switches the
// thread's changes highlighted or not; a plain changed screen switches to its
// highlighted view, in the same state.
test("the floating panel switches the highlighting of a thread's changes off, and on from a plain changed screen", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const repo = path.join(tmp, "styled")
  await fs.writeFile(path.join(repo, "designs/admin/bugs.changes.html"),
    `<!doctype html><html><head><title>Bug Reporting</title><script src="../../runtime/flosis.js"></script></head>
     <body><h1 data-flosis-change="updated">Bug Reporting</h1></body></html>`)
  const context = await ownTab()
  const page = await context.newPage()
  const outline = () => page.$eval("h1", (h1) => getComputedStyle(h1).outlineStyle)
  const toggle = "[data-flosis-dock] input[data-flosis-highlight]"
  await page.goto(`${base}/styled/designs/admin/bugs.changes.html`)
  await page.evaluate(() => window.Flosis.ready)
  assert.equal(await page.isChecked(toggle), true)
  assert.equal(await outline(), "dashed")
  await page.uncheck(toggle)
  assert.equal(await outline(), "none")
  await page.reload()
  await page.evaluate(() => window.Flosis.ready)
  assert.equal(await page.isChecked(toggle), false)
  assert.equal(await outline(), "none")
  await page.check(toggle)
  assert.equal(await outline(), "dashed")

  await page.goto(`${base}/styled/designs/admin/bugs.html#x`)
  await page.evaluate(() => window.Flosis.ready)
  assert.equal(await page.isChecked(toggle), false)
  await Promise.all([ page.waitForURL(/bugs\.changes\.html#x$/), page.check(toggle) ])
  await context.close()
})

test("inside the canvas a screen tells it its states, and the canvas picks one", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  const repo = path.join(tmp, "styled")
  await writeStates(repo)
  await fs.writeFile(path.join(repo, "canvas-states.html"), `<!doctype html><html><body>
    <script>window.told = []; addEventListener("message", (e) => window.told.push(e.data))</script>
    <iframe src="designs/admin/usage.html#reset"></iframe></body></html>`)
  const page = await browser.newPage()
  await page.goto(`${base}/styled/canvas-states.html`)
  await page.waitForFunction(() => window.told.some((m) => m.type === "flosis:states"))
  assert.deepEqual(await page.evaluate(() => window.told.find((m) => m.type === "flosis:states")), {
    type: "flosis:states", state: "reset",
    states: [ { key: "default", label: "This month" }, { key: "over-limit", label: "Over the limit" }, { key: "reset", label: "Reset" } ]
  })
  const frame = page.frames().find((f) => f.url().includes("usage.html"))
  assert.equal(await frame.$("[data-flosis-states]"), null)

  await page.evaluate(() => document.querySelector("iframe").contentWindow.postMessage({ type: "flosis:set-state", state: "over-limit" }, "*"))
  await page.waitForFunction(() => window.told.filter((m) => m.type === "flosis:states").at(-1).state === "over-limit")
  assert.equal(await frame.evaluate(() => location.hash), "#over-limit")
  await page.close()
})
