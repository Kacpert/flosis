// The app's designs-accepting controller (app/javascript/controllers/
// designs_accepting_controller.js) in Chromium, with the app's own Stimulus.
// Kacper (2026-11-23): "żeby user wiedział na co czeka". Accept puts the
// steps in place of the question; the acceptance's own window hides on Hide
// for that acceptance in this tab.
import { test, before, after } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs/promises"
import http from "node:http"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { chromium } from "playwright"

const here = path.dirname(fileURLToPath(import.meta.url))
const app = path.join(here, "../../..")
const controller = path.join(app, "app/javascript/controllers/designs_accepting_controller.js")
let server, base, browser, stimulus, canRun = true

const PAGE = `<!doctype html><html><head>
<style>.hidden { display: none }</style>
<script type="importmap">{ "imports": { "@hotwired/stimulus": "/stimulus.js" } }</script>
<script type="module">
  import { Application } from "@hotwired/stimulus"
  import Accepting from "/controller.js"
  Application.start().register("designs-accepting", Accepting)
</script></head>
<body>
  <div id="dialog" data-controller="designs-accepting">
    <div id="progress" class="hidden" data-designs-accepting-target="progress">Merging into master</div>
    <div id="confirm" data-designs-accepting-target="confirm">
      <form action="/merge" method="post" data-action="submit->designs-accepting#start"><button id="accept">Accept designs</button></form>
    </div>
  </div>
  <div id="window" data-controller="designs-accepting" data-designs-accepting-key-value="designs.acceptanceHidden.5.9"
       data-action="click->designs-accepting#hide">
    <div id="panel" data-action="click->designs-accepting#keep">Writing the description <button id="hide" data-action="designs-accepting#hide">Hide</button></div>
  </div>
</body></html>`

before(async () => {
  try {
    const gem = execFileSync("bundle", [ "exec", "ruby", "-e", "print Gem.loaded_specs['stimulus-rails'].full_gem_path" ],
                             { cwd: app, encoding: "utf8", stdio: [ "ignore", "pipe", "ignore" ] })
    stimulus = await fs.readFile(path.join(gem, "app/assets/javascripts/stimulus.js"))
    browser = await chromium.launch()
  } catch {
    canRun = false
    return
  }
  server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost")
    if (req.method === "POST") {
      // The merge takes its time; the page stays meanwhile.
      req.resume()
      req.on("end", () => res.writeHead(204).end())
    } else if (url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html" }).end(PAGE)
    } else if (url.pathname === "/stimulus.js") {
      res.writeHead(200, { "content-type": "text/javascript" }).end(stimulus)
    } else if (url.pathname === "/controller.js") {
      res.writeHead(200, { "content-type": "text/javascript" }).end(await fs.readFile(controller))
    } else {
      res.writeHead(404).end()
    }
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  base = `http://127.0.0.1:${server.address().port}`
})

after(async () => {
  await browser?.close()
  await new Promise((resolve) => (server ? server.close(resolve) : resolve()))
})

const shown = (page, id) => page.evaluate((selector) => document.querySelector(selector).checkVisibility(), `#${id}`)

test("Accept puts the steps in place of the question", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto(base)
  assert.deepEqual([ await shown(page, "confirm"), await shown(page, "progress") ], [ true, false ])
  await page.click("#accept")
  await page.waitForTimeout(200)
  assert.deepEqual([ await shown(page, "confirm"), await shown(page, "progress") ], [ false, true ])
  await context.close()
})

test("the acceptance's window stays for a click inside, hides on Hide, and stays hidden in this tab only", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto(base)
  await page.click("#panel", { position: { x: 5, y: 5 } })
  assert.equal(await shown(page, "window"), true)
  await page.click("#hide")
  assert.equal(await shown(page, "window"), false)
  await page.reload()
  await page.waitForTimeout(200)
  assert.equal(await shown(page, "window"), false)

  const other = await context.newPage()
  await other.goto(base)
  await other.waitForTimeout(200)
  assert.equal(await shown(other, "window"), true)
  await context.close()
})
