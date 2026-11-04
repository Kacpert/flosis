// The browser of a setup turn (the Designs setup, feature by feature): an MCP
// server on stdio, flosis_browser, that Claude drives through the Claude CLI.
// It reads its config from the file FLOSIS_BROWSER_CONFIG names:
//
//   { "baseUrl", "contexts": [{ "slug", "name", "statePath" }], "worktree",
//     "progressPath", "featuresPath", "featureKey", "viewport" }
//
// Each context is a browser of its own, started from the state sign_in.mjs
// left for it, so no password ever reaches this process. The app is the test
// environment at baseUrl: the browser never goes to another origin and never
// clicks a control that signs out. The designs Claude writes are served from
// the worktree on 127.0.0.1, for it to open, check and compare with the app.
import fs from "node:fs/promises"
import http from "node:http"
import path from "node:path"
import { chromium } from "playwright"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"
import { CHROMIUM_ARGS, NOT_ALLOWED, SIGNS_OUT, emailField, sameOrigin, signOut, testDomain, valueFor } from "./browser_lib.mjs"

const config = JSON.parse(await fs.readFile(process.env.FLOSIS_BROWSER_CONFIG, "utf8"))
const viewport = config.viewport || { width: 1440, height: 900 }
// The tallest screenshot sent: the API refuses larger images once a request
// holds many of them.
const MAX_SHOT = 2_000
const TYPES = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json",
                ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
                ".webp": "image/webp", ".ico": "image/x-icon", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf" }

let browser
let designs
const pages = new Map()
const said = new WeakMap()

const server = new McpServer({ name: "flosis_browser", version: "1.0.0" })
const context = z.string().describe(`The context to act as: ${config.contexts.map((c) => `${c.slug} (${c.name})`).join(", ")}`)

tool("open", "Opens a page of the app as a context and shows it: its address, its numbered elements and its text.",
     { context, path: z.string().describe("The page's path in the app, such as /projects") },
     async (args) => text(await open(args)))
tool("click", "Clicks an element of the page a context has open, by its number from open (e12), and shows the page after.",
     { context, ref: z.string().describe("The element's number, such as e12") },
     async (args) => text(await click(args)))
tool("fill_form", "Fills a whole form at once with plausible test data, or wrongly in invalid mode to show its errors. " +
     "Values you give win, by label, name or id. Password fields are never filled.",
     { context, ref: z.string().optional().describe("The form or an element in it; the page's first form when left out"),
       values: z.record(z.string(), z.string()).optional().describe("Values that matter, by label, name or id"),
       mode: z.enum([ "valid", "invalid" ]).optional(), submit: z.boolean().optional().describe("Submit the form after filling it") },
     async (args) => text(await fillForm(args)))
tool("screenshot", "Shows what a context's page looks like.",
     { context, full_page: z.boolean().optional() },
     async ({ context: slug, full_page: fullPage }) => ({ content: await shot(await pageFor(slug), fullPage) }))
tool("design", "Opens a design from the repository (designs/<context>/<screen>.html) and shows it, with its script errors.",
     { path: z.string().describe("The design's path in the repository") },
     async (args) => text(await design(args)))
tool("click_design", "Clicks an element of the design open in design, by its number (d12), and shows the design after: to click through a design's flows.",
     { ref: z.string().describe("The element's number from design, such as d12") },
     async (args) => text(await clickDesign(args)))
tool("compare", "Shows a page of the app and a design side by side, at the same size, to compare them.",
     { context, app_path: z.string(), design_path: z.string(), full_page: z.boolean().optional() },
     async (args) => compare(args))
tool("check_design", "Checks a design: script errors, links to files that do not exist, components that failed to load.",
     { path: z.string() },
     async (args) => text(await checkDesign(args)))
tool("progress", "Records where the feature is: a screen being built, being checked, or done.",
     { screen: z.string(), status: z.enum([ "building", "checking", "done" ]) },
     async (args) => text(await progress(args)))
if (config.featuresPath) {
  tool("save_features", "Saves the feature map, in the order the features are to be built.",
       { features: z.array(z.object({ name: z.string().min(1), contexts: z.array(z.string()).default([]),
                                      screens: z.array(z.string()).default([]), brief: z.string().default(""),
                                      notes: z.array(z.string()).default([]), key: z.string().optional(),
                                      changes: z.string().optional() })).min(1) },
       async (args) => text(await saveFeatures(args)))
}

await server.connect(new StdioServerTransport())
process.stdin.on("close", shutdown)
process.on("SIGTERM", shutdown)

// A tool whose failure is told to Claude, never thrown at the CLI.
function tool(name, description, inputSchema, handler) {
  server.registerTool(name, { description, inputSchema }, async (args) => {
    try {
      return await handler(args)
    } catch (error) {
      return { content: [ { type: "text", text: `Error: ${String(error.message || error).split("\n")[0]}` } ], isError: true }
    }
  })
}

function text(value) {
  return { content: [ { type: "text", text: value } ] }
}

async function launch() {
  browser ??= await chromium.launch({ args: CHROMIUM_ARGS })
  return browser
}

// A context's page, made on first use from the state sign_in.mjs left. A tab
// it opens is closed: one inside the app is followed in the page instead, one
// outside it is refused.
async function pageFor(slug) {
  if (pages.has(slug)) return pages.get(slug)
  const entry = config.contexts.find((candidate) => candidate.slug === slug)
  if (!entry) throw new Error(`There is no context ${slug}. The contexts are ${config.contexts.map((c) => c.slug).join(", ")}.`)
  const browserContext = await (await launch()).newContext({ viewport, storageState: entry.statePath, acceptDownloads: false })
  const page = await browserContext.newPage()
  watch(page)
  browserContext.on("page", async (tab) => {
    const url = tab.url() === "about:blank" ? await tab.waitForEvent("framenavigated").then(() => tab.url()).catch(() => tab.url()) : tab.url()
    await tab.close().catch(() => {})
    if (sameOrigin(config.baseUrl, url)) await page.goto(url).catch(() => {})
    else page.flosisRefused = true
  })
  pages.set(slug, page)
  return page
}

// What a page says that Claude should hear: script errors and the dialogs it
// accepted.
function watch(page) {
  said.set(page, [])
  page.on("console", (message) => message.type() === "error" && said.get(page).push(`Script error: ${message.text()}`))
  page.on("pageerror", (error) => said.get(page).push(`Script error: ${error.message}`))
  page.on("dialog", async (dialog) => {
    said.get(page).push(`Dialog "${dialog.message()}": accepted`)
    await dialog.accept().catch(() => {})
  })
}

async function settle(page) {
  await page.waitForLoadState("load", { timeout: 15_000 }).catch(() => {})
  await page.waitForLoadState("networkidle", { timeout: 3_000 }).catch(() => {})
}

async function open({ context: slug, path: where }) {
  if (signOut("", where)) return SIGNS_OUT
  const page = await pageFor(slug)
  const url = new URL(where, config.baseUrl).href
  if (!sameOrigin(config.baseUrl, url)) return NOT_ALLOWED
  await page.goto(url, { timeout: 30_000 })
  await settle(page)
  if (!sameOrigin(config.baseUrl, page.url())) {
    await page.goBack().catch(() => {})
    return NOT_ALLOWED
  }
  return state(page)
}

async function click({ context: slug, ref }) {
  const page = await pageFor(slug)
  const target = page.locator(`[data-flosis-ref="${ref}"]`)
  if (!(await target.count())) return `There is no element ${ref} on the page: call open again for fresh numbers.`
  const facts = await target.first().evaluate((element) => ({
    text: (element.innerText || element.getAttribute("aria-label") || element.value || "").trim(),
    href: element.getAttribute("href") || "",
    action: element.form ? element.form.getAttribute("action") || "" : "",
  }))
  if (signOut(facts.text, facts.href) || signOut("", facts.action)) return SIGNS_OUT
  if (facts.href && !sameOrigin(config.baseUrl, new URL(facts.href, page.url()).href)) return `${NOT_ALLOWED}\n\n${await state(page)}`

  const before = page.url()
  page.flosisRefused = false
  await target.first().click({ timeout: 10_000 })
  await settle(page)
  if (!sameOrigin(config.baseUrl, page.url())) {
    await page.goto(before).catch(() => {})
    await settle(page)
    return `${NOT_ALLOWED}\n\n${await state(page)}`
  }
  if (page.flosisRefused) return `${NOT_ALLOWED}\n\n${await state(page)}`
  return state(page)
}

// Fills the form ref names (or the one ref is in, or the page's first) at
// once, then submits it if asked. Every field gets a value from values, by
// label, name or id, or one of valueFor's; a password field never does.
async function fillForm({ context: slug, ref, values = {}, mode = "valid", submit = false }) {
  const page = await pageFor(slug)
  const root = ref ? await page.$(`[data-flosis-ref="${ref}"]`) : null
  if (ref && !root) return `There is no element ${ref} on the page: call open again for fresh numbers.`
  const fields = await page.evaluate(describeFields, root)
  if (!fields.length) return `There is no form to fill here.\n\n${await state(page)}`
  const keep = (field) => mode === "valid" && (field.type === "checkbox" ? field.checked : field.value !== "")

  const wanted = Object.fromEntries(Object.entries(values).map(([key, value]) => [ key.trim().toLowerCase(), value ]))
  const lines = []
  const radios = new Set()
  for (const field of fields) {
    const name = field.label || field.name || field.domId || field.type
    if (field.type === "password") {
      lines.push(`- ${name}: left empty (password fields are never filled)`)
      continue
    }
    const given = [ field.label, field.name, field.domId ].map((key) => String(key || "").trim().toLowerCase()).find((key) => key && key in wanted)
    const locator = page.locator(`[data-flosis-field="${field.id}"]`)
    if (field.type === "radio") {
      if (given !== undefined) {
        if (String(wanted[given]) === field.value || String(wanted[given]).toLowerCase() === field.label.toLowerCase()) {
          await locator.check()
          lines.push(`- ${field.name} = ${field.value}`)
        }
      } else if (mode === "valid" && !radios.has(field.name) && !field.groupChecked) {
        await locator.check()
        lines.push(`- ${field.name} = ${field.value}`)
      }
      radios.add(field.name)
      continue
    }
    if (given === undefined && keep(field)) continue
    let value = given !== undefined ? wanted[given] : valueFor(field, mode)
    if (value === null || value === undefined) continue
    if (given !== undefined && mode === "valid" && emailField(field)) value = testDomain(value)
    if (field.type === "checkbox") {
      const on = value === true || String(value).toLowerCase() === "true" || String(value).toLowerCase() === "on"
      await locator.setChecked(on)
      lines.push(`- ${name} = ${on ? "checked" : "unchecked"}`)
    } else if (field.type === "select") {
      await locator.selectOption(String(value)).catch(() => locator.selectOption({ label: String(value) }))
      lines.push(`- ${name} = ${value}`)
    } else {
      await locator.fill(String(value))
      lines.push(`- ${name} = ${value}`)
    }
  }

  let after = ""
  if (submit) {
    // The submit button is clicked as a person would, so Playwright waits for
    // the navigation it starts; a form without one is submitted in the page.
    const submitted = await page.evaluate(({ id, invalid }) => {
      document.querySelectorAll("[data-flosis-submit]").forEach((element) => element.removeAttribute("data-flosis-submit"))
      const form = document.querySelector(`[data-flosis-field="${id}"]`)?.form
      if (!form) return null
      if (invalid) form.noValidate = true
      const button = form.querySelector("button[type=submit], input[type=submit], button:not([type])")
      if (button) button.setAttribute("data-flosis-submit", "")
      return { text: button ? (button.innerText || button.value || "").trim() : "", button: !!button }
    }, { id: fields[0].id, invalid: mode === "invalid" })
    if (!submitted) return `Filled:\n${lines.join("\n") || "- nothing"}\n\nThere is no form to submit: these fields are in none.\n\n${await state(page)}`
    if (signOut(submitted.text, "")) return SIGNS_OUT
    const before = page.url()
    if (submitted.button) {
      await page.locator("[data-flosis-submit]").first().click({ timeout: 10_000 })
    } else {
      await Promise.all([
        page.waitForEvent("framenavigated", { timeout: 5_000 }).catch(() => null),
        page.evaluate((id) => document.querySelector(`[data-flosis-field="${id}"]`)?.form?.requestSubmit(), fields[0].id),
      ])
    }
    await settle(page)
    if (!sameOrigin(config.baseUrl, page.url())) {
      await page.goto(before).catch(() => {})
      after = `${NOT_ALLOWED}\n`
    }
  }
  return `Filled:\n${lines.join("\n") || "- nothing"}\n\n${after}${await state(page)}`
}

// In the page: the fields fill_form can fill, under root (an element, its
// form, or the page's first form), each marked with data-flosis-field.
function describeFields(root) {
  document.querySelectorAll("[data-flosis-field]").forEach((element) => element.removeAttribute("data-flosis-field"))
  const fillable = (element) => {
    const type = (element.localName === "input" ? element.getAttribute("type") || "text" : element.localName).toLowerCase()
    if ([ "hidden", "submit", "button", "reset", "image", "file" ].includes(type) || element.disabled || element.readOnly) return null
    const box = element.getBoundingClientRect()
    if (box.width === 0 && box.height === 0 && type !== "checkbox" && type !== "radio") return null
    return type
  }
  const hasFields = (form) => [ ...form.querySelectorAll("input, select, textarea") ].some((element) => fillable(element))
  const form = root ? (root.localName === "form" ? root : root.closest("form")) : [ ...document.forms ].find(hasFields)
  const scope = form || root || document.body
  const fields = []
  let n = 0
  for (const element of scope.querySelectorAll("input, select, textarea")) {
    const type = fillable(element)
    if (!type) continue
    const id = `f${++n}`
    element.setAttribute("data-flosis-field", id)
    const label = (element.labels && element.labels[0] ? element.labels[0].innerText : element.getAttribute("aria-label") || element.getAttribute("placeholder") || "")
      .trim().replace(/\s+/g, " ")
    fields.push({
      id, type, label, name: element.getAttribute("name") || "", domId: element.id || "", value: element.value, checked: element.checked,
      required: element.required, min: element.getAttribute("min"), max: element.getAttribute("max"),
      minLength: element.minLength > 0 ? element.minLength : null, maxLength: element.maxLength > 0 ? element.maxLength : null,
      pattern: element.getAttribute("pattern"),
      options: element.localName === "select" ? [ ...element.options ].map((option) => ({ value: option.value, text: option.text })) : null,
      groupChecked: type === "radio" ? !!scope.querySelector(`input[type=radio][name="${CSS.escape(element.name)}"]:checked`) : false,
    })
  }
  return fields
}

// A page as Claude reads it: where it is, its elements, each numbered for
// click, and its text, then what it said since the last look.
async function state(page) {
  const facts = await page.evaluate(markElements, { prefix: page.flosisPrefix || "e", from: page.flosisNext || 1 })
    .catch(() => ({ elements: [], text: "", next: page.flosisNext || 1 }))
  page.flosisNext = facts.next
  const where = new URL(page.url())
  const base = sameOrigin(config.baseUrl, page.url()) || where.hostname === "127.0.0.1" ? `${where.pathname}${where.search}` : page.url()
  const notes = said.get(page).splice(0)
  return [ `URL: ${base} (${await page.title().catch(() => "")})`, ...notes, "Elements:", ...facts.elements, "Text:", facts.text ].join("\n")
}

// Numbers each element afresh, from where the page's last look stopped, so a
// number from an earlier look names nothing and is refused rather than
// clicked on whatever took its place.
function markElements({ prefix, from }) {
  const selector = "a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=tab], " +
                   "[role=menuitem], [role=checkbox], [role=switch], [role=option], [contenteditable=''], [contenteditable=true]"
  document.querySelectorAll("[data-flosis-ref]").forEach((element) => element.removeAttribute("data-flosis-ref"))
  const shown = (element) => {
    const box = element.getBoundingClientRect()
    const style = getComputedStyle(element)
    return (box.width > 0 || box.height > 0) && style.visibility !== "hidden" && style.display !== "none"
  }
  const nameOf = (element) => {
    const label = element.labels && element.labels[0] ? element.labels[0].innerText : ""
    const value = element.type === "password" ? "" : element.localName === "input" && [ "submit", "button" ].includes(element.type) ? element.value : ""
    return (element.getAttribute("aria-label") || label || element.getAttribute("placeholder") || element.innerText || value ||
            element.getAttribute("title") || element.getAttribute("name") || "").trim().replace(/\s+/g, " ").slice(0, 80)
  }
  const roleOf = (element) => {
    if (element.getAttribute("role")) return element.getAttribute("role")
    if (element.localName === "a") return "link"
    if (element.localName === "select") return "select"
    if (element.localName === "textarea") return "textbox"
    if (element.localName === "input") return [ "checkbox", "radio", "submit", "button" ].includes(element.type) ? element.type : "textbox"
    return element.localName
  }
  const elements = []
  let n = from - 1
  let count = 0
  for (const element of document.querySelectorAll(selector)) {
    if (!shown(element)) continue
    const ref = `${prefix}${++n}`
    element.setAttribute("data-flosis-ref", ref)
    let line = `[${ref}] ${roleOf(element)} "${nameOf(element)}"`
    if (element.localName === "a") line += ` → ${element.getAttribute("href")}`
    if (element.localName === "input" && ![ "checkbox", "radio", "submit", "button", "text" ].includes(element.type)) line += ` (${element.type})`
    if (element.required) line += " required"
    if (element.disabled) line += " disabled"
    if (element.checked) line += " checked"
    elements.push(line)
    if (++count >= 250) break
  }
  const text = (document.body ? document.body.innerText : "").replace(/\n{3,}/g, "\n\n").slice(0, 4_000)
  return { elements, text, next: n + 1 }
}

// A screenshot, as MCP content: a full page is cut at MAX_SHOT pixels, and
// says so.
async function shot(page, fullPage = false) {
  const height = fullPage ? await page.evaluate(() => document.documentElement.scrollHeight).catch(() => viewport.height) : viewport.height
  const cut = fullPage && height > MAX_SHOT
  const clip = cut ? { x: 0, y: 0, width: viewport.width, height: MAX_SHOT } : undefined
  const data = await page.screenshot({ fullPage: !!fullPage, clip, timeout: 30_000 })
  const image = { type: "image", data: data.toString("base64"), mimeType: "image/png" }
  return cut ? [ { type: "text", text: `The page is ${height} px tall: this shows its first ${MAX_SHOT} px.` }, image ] : [ image ]
}

// The designs, served from the worktree on 127.0.0.1, and one page to show
// them in, outside every context.
async function designPage() {
  if (!designs) {
    const root = await fs.realpath(config.worktree)
    const files = http.createServer(async (request, response) => {
      try {
        const file = path.resolve(root, `.${decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname)}`)
        const stat = await fs.stat(file)
        const target = await fs.realpath(stat.isDirectory() ? path.join(file, "index.html") : file)
        if (!target.startsWith(root + path.sep)) throw new Error("outside")
        response.writeHead(200, { "content-type": TYPES[path.extname(target).toLowerCase()] || "application/octet-stream", "cache-control": "no-store" })
        response.end(await fs.readFile(target))
      } catch {
        response.writeHead(404).end()
      }
    })
    await new Promise((resolve) => files.listen(0, "127.0.0.1", resolve))
    const page = await (await (await launch()).newContext({ viewport })).newPage()
    page.flosisPrefix = "d"
    watch(page)
    designs = { files, page, root, url: `http://127.0.0.1:${files.address().port}` }
  }
  return designs
}

// A design's path, inside the worktree, or null.
function designPath(where) {
  const clean = String(where || "").replace(/^\/+/, "")
  const resolved = path.resolve(config.worktree, clean)
  return resolved.startsWith(path.resolve(config.worktree) + path.sep) ? clean : null
}

async function showDesign(where) {
  const clean = designPath(where)
  if (!clean) return null
  const { page, url } = await designPage()
  said.get(page).splice(0)
  await page.goto(`${url}/${clean}`, { timeout: 30_000 })
  await settle(page)
  await page.evaluate(() => (window.Flosis && window.Flosis.ready ? Promise.race([ window.Flosis.ready, new Promise((r) => setTimeout(r, 5_000)) ]) : null))
    .catch(() => {})
  return page
}

async function design({ path: where }) {
  const page = await showDesign(where)
  if (!page) return "Not allowed: a design is a file of the repository."
  return state(page)
}

// A click on the design open in design: a design's links and buttons are
// followed as a person would follow them. It never leaves the worktree's
// server.
async function clickDesign({ ref }) {
  if (!designs) return "No design is open: call design first."
  const { page, url } = designs
  const target = page.locator(`[data-flosis-ref="${ref}"]`)
  if (!(await target.count())) return `There is no element ${ref} on the design: call design again for fresh numbers.`
  const before = page.url()
  await target.first().click({ timeout: 10_000 })
  await settle(page)
  if (!page.url().startsWith(`${url}/`)) {
    await page.goto(before).catch(() => {})
    await settle(page)
    return `Not allowed: that leaves the designs.\n\n${await state(page)}`
  }
  return state(page)
}

async function compare({ context: slug, app_path: appPath, design_path: designAt, full_page: fullPage }) {
  const opened = await open({ context: slug, path: appPath })
  if (opened === NOT_ALLOWED) return text(NOT_ALLOWED)
  const page = await showDesign(designAt)
  if (!page) return text("Not allowed: a design is a file of the repository.")
  return {
    content: [
      { type: "text", text: `The app, ${appPath}, as ${slug}:` }, ...(await shot(await pageFor(slug), fullPage)),
      { type: "text", text: `The design, ${designAt}:` }, ...(await shot(page, fullPage)),
    ],
  }
}

async function checkDesign({ path: where }) {
  const page = await showDesign(where)
  if (!page) return "Not allowed: a design is a file of the repository."
  const { root } = await designPage()
  const errors = said.get(page).splice(0).filter((line) => line.startsWith("Script error"))
  const found = await page.evaluate(() => ({
    links: [ ...document.querySelectorAll("a[href]") ].map((a) => a.getAttribute("href")),
    failed: [ ...document.querySelectorAll("[data-flosis-error]") ].map((box) => box.innerText.trim()),
  }))
  const pageUrl = new URL(page.url())
  const missing = []
  for (const href of found.links) {
    if (!href || /^(#|mailto:|tel:|javascript:|https?:|\/\/|data:)/i.test(href)) continue
    const target = new URL(href, pageUrl)
    const file = path.join(root, decodeURIComponent(target.pathname))
    if (!(await fs.stat(file).then((stat) => stat.isFile() || stat.isDirectory()).catch(() => false))) missing.push(href)
  }
  const lines = [ where ]
  lines.push(errors.length ? `Script errors: ${errors.map((line) => line.replace("Script error: ", "")).join(" | ")}` : "Script errors: none")
  lines.push(missing.length ? `Links to files that do not exist: ${[ ...new Set(missing) ].join(", ")}` : "Links to files that do not exist: none")
  lines.push(found.failed.length ? `Components that failed: ${found.failed.join(" | ")}` : "Components that failed: none")
  return lines.join("\n")
}

async function progress({ screen, status }) {
  const current = await fs.readFile(config.progressPath, "utf8").then(JSON.parse).catch(() => ({}))
  const data = current.feature === config.featureKey && current.screens ? current : { feature: config.featureKey, screens: {} }
  data.screens[screen] = status
  await write(config.progressPath, JSON.stringify(data))
  return `${screen}: ${status}`
}

async function saveFeatures({ features }) {
  await write(config.featuresPath, JSON.stringify(features, null, 2))
  return `Saved ${features.length} feature${features.length === 1 ? "" : "s"}.`
}

// Written whole or not at all: a reader never sees half a file.
async function write(file, contents) {
  const temporary = `${file}.${process.pid}.tmp`
  await fs.writeFile(temporary, contents, { mode: 0o600 })
  await fs.rename(temporary, file)
}

async function shutdown() {
  await browser?.close().catch(() => {})
  designs?.files.close()
  process.exit(0)
}
