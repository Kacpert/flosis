// The app's designs-images controller (app/javascript/controllers/
// designs_images_controller.js) in Chromium, with the app's own Stimulus.
// Kacper (2026-11-23): switching the view on the Designs screen reloads the
// page, and the images waiting for the message were gone while its text
// stayed. They are kept for the thread in this tab until the message is sent.
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
const controller = path.join(app, "app/javascript/controllers/designs_images_controller.js")
// A 1×1 PNG.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64")
let server, base, browser, stimulus, canRun = true

const PAGE = `<!doctype html><html><head>
<script type="importmap">{ "imports": { "@hotwired/stimulus": "/stimulus.js" } }</script>
<script type="module">
  import { Application } from "@hotwired/stimulus"
  import Images from "/controller.js"
  Application.start().register("designs-images", Images)
</script></head>
<body><div data-controller="designs-images">
  <form action="/message" method="post" enctype="multipart/form-data">
    <div class="hidden" data-designs-images-target="previews"></div>
    <textarea name="text">Make it blue</textarea>
    <input type="file" name="images[]" multiple data-designs-images-target="input" data-draft-key="designs.images.7"
           data-action="change->designs-images#picked">
    <button type="submit">Send</button>
  </form>
</div></body></html>`

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
      req.resume()
      req.on("end", () => res.writeHead(303, { location: "/" }).end())
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

// The thumbnails waiting above the box, and the files the form would send.
async function waiting(page) {
  await page.waitForTimeout(300)
  return page.evaluate(() => ({
    thumbnails: [ ...document.querySelectorAll("[data-designs-images-target=previews] img") ].map((img) => img.alt),
    files: [ ...document.querySelector("input[type=file]").files ].map((file) => file.name)
  }))
}

async function addImages(page, ...names) {
  await page.setInputFiles("input[type=file]", names.map((name) => ({ name, mimeType: "image/png", buffer: PNG })))
}

test("images waiting for the message come back after the page reloads", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto(base)
  await addImages(page, "billing.png", "consumption.png")
  assert.deepEqual(await waiting(page), { thumbnails: [ "billing.png", "consumption.png" ], files: [ "billing.png", "consumption.png" ] })

  await page.reload()
  assert.deepEqual(await waiting(page), { thumbnails: [ "billing.png", "consumption.png" ], files: [ "billing.png", "consumption.png" ] })

  // The test page has no styles: the thumbnails' × buttons overlap, so the click goes to the button itself.
  await page.$eval("[aria-label='Remove billing.png']", (button) => button.click())
  await page.reload()
  assert.deepEqual(await waiting(page), { thumbnails: [ "consumption.png" ], files: [ "consumption.png" ] })
  await context.close()
})

test("a sent message takes its images with it, and another tab has its own", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto(base)
  await addImages(page, "billing.png")

  const other = await context.newPage()
  await other.goto(base)
  assert.deepEqual(await waiting(other), { thumbnails: [], files: [] })

  await Promise.all([ page.waitForURL(base + "/"), page.click("button[type=submit]") ])
  assert.deepEqual(await waiting(page), { thumbnails: [], files: [] })
  await context.close()
})
