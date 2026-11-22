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

// Kacper (2026-11-19): a preview opened in a tab of its own had no way to the
// other screens. Outside the Designs canvas a screen gets a bar that steps
// through the screens the thread changed (__flosis/changes.json) and lists
// them; inside the canvas, which has its own, there is none.
test("opened in a tab of its own, a changed screen steps to the next change; inside the canvas it has no bar", async (t) => {
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

  const page = await browser.newPage()
  await page.goto(`${base}/styled/designs/admin/bugs.changes.html`)
  await page.evaluate(() => window.Flosis.ready)
  const bar = await page.textContent("[data-flosis-nav]")
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
  assert.equal(await frame.$("[data-flosis-nav]"), null)
  await page.close()
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

test("a tab of its own switches states from a small bar at the top; a test browser and the canvas get none", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot start here")
  await writeStates(path.join(tmp, "styled"))
  const context = await browser.newContext()
  await context.addInitScript(() => Object.defineProperty(Navigator.prototype, "webdriver", { get: () => false }))
  const page = await context.newPage()
  await page.goto(`${base}/styled/designs/admin/usage.html#reset`)
  await page.evaluate(() => window.Flosis.ready)
  assert.deepEqual(await page.$$eval("[data-flosis-states] a", (links) => links.map((link) => [ link.textContent, link.getAttribute("href"), link.hasAttribute("aria-current") ])),
                   [ [ "This month", "#", false ], [ "Over the limit", "#over-limit", false ], [ "Reset", "#reset", true ] ])
  await page.click("[data-flosis-states] a[href='#over-limit']")
  await page.waitForFunction(() => window.Flosis.state === "over-limit")
  assert.equal(await page.getAttribute("[data-flosis-states] a[aria-current]", "href"), "#over-limit")
  await context.close()

  const automated = await browser.newPage()
  await automated.goto(`${base}/styled/designs/admin/usage.html#reset`)
  await automated.evaluate(() => window.Flosis.ready)
  assert.equal(await automated.$("[data-flosis-states]"), null)
  await automated.close()
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
