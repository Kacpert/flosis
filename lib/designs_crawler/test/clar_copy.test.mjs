// The app's clar-copy controller (app/javascript/controllers/
// clar_copy_controller.js) in Chromium, with the app's own Stimulus, set up as
// the Ready screen sets it. Kacper (2026-11-23): Copy said copied and the
// clipboard held nothing.
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
const controller = path.join(app, "app/javascript/controllers/clar_copy_controller.js")
const ready = path.join(app, "app/views/workshop/ideas/_ready.html.erb")
let server, base, browser, stimulus, canRun = true

// The Ready screen's own attributes, read from its view, so the test breaks
// when the view does.
async function page(attributes) {
  return `<!doctype html><html><head>
<script type="importmap">{ "imports": { "@hotwired/stimulus": "/stimulus.js" } }</script>
<script type="module">
  import { Application } from "@hotwired/stimulus"
  import Copy from "/controller.js"
  Application.start().register("clar-copy", Copy)
  window.addEventListener("clar:toast", (event) => { window.toasts = [ ...(window.toasts || []), event.detail.message ] })
</script></head>
<body><div ${attributes}>
  <code data-clar-copy-target="text">git checkout feat/scrum-71-invoicing-and-payments</code>
  <button type="button" id="copy" data-action="clar-copy#copy">Copy</button>
</div></body></html>`
}

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
  const view = (await fs.readFile(ready, "utf8")).replace(/<%=\s*branch\s*%>/g, "feat/scrum-71-invoicing-and-payments")
  const tag = view.match(/<div[^>]*data-controller="clar-copy"[^>]*>/)[0]
  const attributes = tag.replace(/^<div\s*/, "").replace(/>$/, "")
  server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://localhost")
    if (url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html" }).end(await page(attributes))
    } else if (url.pathname === "/empty") {
      res.writeHead(200, { "content-type": "text/html" }).end(await page('data-controller="clar-copy"'))
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

test("Copy on the Ready screen puts the checkout command on the clipboard", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext({ permissions: [ "clipboard-read", "clipboard-write" ] })
  const page = await context.newPage()
  await page.goto(base)
  await page.evaluate(() => navigator.clipboard.writeText("something else"))
  await page.click("#copy")
  await page.waitForTimeout(200)
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), "git checkout feat/scrum-71-invoicing-and-payments")
  assert.deepEqual(await page.evaluate(() => window.toasts), [ "Checkout command copied" ])
  await context.close()
})

test("with nothing to copy, Copy never says it copied", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext({ permissions: [ "clipboard-read", "clipboard-write" ] })
  const page = await context.newPage()
  await page.goto(`${base}/empty`)
  await page.click("#copy")
  await page.waitForTimeout(200)
  assert.deepEqual(await page.evaluate(() => window.toasts), [ "Couldn't copy · it is selected, press ⌘C" ])
  await context.close()
})
