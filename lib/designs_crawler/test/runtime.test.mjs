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
