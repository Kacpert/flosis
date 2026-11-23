// The app's designs-canvas controller (app/javascript/controllers/
// designs_canvas_controller.js) in Chromium, with the app's own Stimulus.
// Kacper (2026-11-23): the preview went back to an old width after a message
// or a switch of view. The size dragged is remembered; a smaller window scales
// the same screen down instead of changing it.
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
const controller = path.join(app, "app/javascript/controllers/designs_canvas_controller.js")
let server, base, browser, stimulus, canRun = true

// The canvas as _canvas.html.erb lays it out, with the styles that matter.
const PAGE = `<!doctype html><html><head>
<style>body { margin: 0 } .edge { position: absolute; z-index: 6; top: 0; bottom: 0; right: -7px; width: 10px; }</style>
<script type="importmap">{ "imports": { "@hotwired/stimulus": "/stimulus.js" } }</script>
<script type="module">
  import { Application } from "@hotwired/stimulus"
  import Canvas from "/controller.js"
  Application.start().register("designs-canvas", Canvas)
</script></head>
<body><div data-controller="designs-canvas">
  <div style="padding: 8px">
    <div style="position: relative; max-width: 1162px; margin: 0 auto" data-designs-canvas-target="box">
      <div style="border: 1px solid #ccc; overflow: hidden">
        <span data-designs-canvas-target="size" hidden></span>
        <div style="width: 100%; overflow: hidden" data-designs-canvas-target="wrap">
          <iframe src="about:blank" style="display: block; border: 0; transform-origin: top left; width: 1160px; height: 860px"
                  data-designs-canvas-target="frame"></iframe>
        </div>
      </div>
      <div class="edge" data-edge="x" data-action="pointerdown->designs-canvas#sizeStart dblclick->designs-canvas#sizeReset"></div>
    </div>
  </div>
  <button type="button" id="copy" data-action="designs-canvas#copyLink"
          data-designs-canvas-template-param="https://app.example/flosis/SCRUM-54/wip/{context}/{screen}"
          data-designs-canvas-context-param="admin" data-designs-canvas-screen-param="consumption">Copy link</button>
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
    if (url.pathname === "/") {
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

// The frame's width as the screen gets it, its scale, and the size in the bar.
async function frame(page) {
  await page.waitForTimeout(200)
  return page.evaluate(() => {
    const frame = document.querySelector("iframe")
    const size = document.querySelector("[data-designs-canvas-target=size]")
    return { width: frame.style.width, scale: frame.style.transform, size: size.hidden ? null : size.textContent }
  })
}

test("the width dragged stays after the page reloads, and a smaller window scales it down", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext({ viewport: { width: 1400, height: 1100 } })
  const page = await context.newPage()
  await page.goto(base)
  assert.deepEqual(await frame(page), { width: "1160px", scale: "scale(1)", size: null })

  const edge = await page.locator(".edge").boundingBox()
  await page.mouse.move(edge.x + edge.width / 2, edge.y + 100)
  await page.mouse.down()
  await page.mouse.move(edge.x - 40, edge.y + 100, { steps: 4 })
  await page.mouse.move(edge.x - 80, edge.y + 100, { steps: 4 })
  await page.mouse.up()
  const dragged = await frame(page)
  assert.notEqual(dragged.width, "1160px")
  assert.equal(dragged.size, `${parseInt(dragged.width, 10)} × 860`)

  await page.reload()
  assert.deepEqual(await frame(page), dragged)

  // A smaller window: the same screen, scaled down to fit.
  await page.setViewportSize({ width: 700, height: 900 })
  const smaller = await frame(page)
  assert.equal(smaller.width, dragged.width)
  assert.ok(parseFloat(smaller.scale.replace("scale(", "")) < 1, smaller.scale)
  await page.reload()
  assert.equal((await frame(page)).width, dragged.width)
  await context.close()
})

test("a double-click on an edge puts back the standard size for good", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext({ viewport: { width: 1400, height: 1100 } })
  const page = await context.newPage()
  await page.goto(base)
  await page.evaluate(() => localStorage.setItem("designs.frameSize", JSON.stringify({ width: 900, height: 700 })))
  await page.reload()
  assert.deepEqual(await frame(page), { width: "900px", scale: "scale(1)", size: "900 × 700" })

  await page.dblclick(".edge")
  await page.reload()
  assert.deepEqual(await frame(page), { width: "1160px", scale: "scale(1)", size: null })
  await context.close()
})

// Kacper (2026-11-23): a link to send someone, to the screen and the state shown.
test("Copy link copies the short link to the screen and the state the preview shows", async (t) => {
  if (!canRun) return t.skip("no Chromium or no stimulus-rails here")
  const context = await browser.newContext({ viewport: { width: 1400, height: 1100 }, permissions: [ "clipboard-read", "clipboard-write" ] })
  const page = await context.newPage()
  await page.goto(base)
  const copied = async () => {
    await page.click("#copy")
    await page.waitForTimeout(100)
    return page.evaluate(() => navigator.clipboard.readText())
  }
  // Before the preview says anything: the screen the page opened with.
  assert.equal(await copied(), "https://app.example/flosis/SCRUM-54/wip/admin/consumption")

  // The preview tells its screen, then its state, as runtime/flosis.js does.
  const tell = (message) => page.evaluate((data) => {
    document.querySelector("iframe").contentWindow.eval(`parent.postMessage(${JSON.stringify(data)}, "*")`)
  }, message)
  await tell({ type: "flosis:screen", context: "admin", screen: "billing", title: "Billing" })
  await tell({ type: "flosis:states", states: [ { key: "default", label: "This month" }, { key: "paused", label: "AI paused" } ], state: "paused" })
  await page.waitForTimeout(100)
  assert.equal(await copied(), "https://app.example/flosis/SCRUM-54/wip/admin/billing#paused")

  await tell({ type: "flosis:states", states: [ { key: "default", label: "This month" }, { key: "paused", label: "AI paused" } ], state: "default" })
  await page.waitForTimeout(100)
  assert.equal(await copied(), "https://app.example/flosis/SCRUM-54/wip/admin/billing")

  // A context named as a link's own word keeps the page's path.
  await tell({ type: "flosis:screen", context: "wip", screen: "jobs", title: "Jobs" })
  await page.waitForTimeout(100)
  assert.equal(await copied(), "https://app.example/flosis/SCRUM-54/wip/designs/wip/jobs.html")
  await context.close()
})
