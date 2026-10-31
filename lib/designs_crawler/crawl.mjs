// Crawls a running app as each of a Flosis setup run's roles, and writes what
// it saw to a folder: a full-page screenshot and the DOM of every page, per
// role, and a crawl.json summary with the app's most used colours and fonts.
//
//   node crawl.mjs <outDir>   (input as JSON on stdin)
//   { "baseUrl", "maxPagesPerRole", "roles": [{ "name", "loginUrl", "username", "password", "notes" }] }
//
// Credentials arrive on stdin only, and nothing here prints them. Before a
// page is captured, every password field is emptied and any text or field
// value holding a role's password is masked, so neither the screenshot nor
// the DOM keeps one. Exit 0 when at least one role was crawled, 2 when none
// was, 1 on anything else.
import { chromium } from "playwright"
import fs from "node:fs/promises"
import path from "node:path"

const MASK = "••••••"
// Links a crawl must not follow: they end the session or change data.
const UNSAFE = /log\s*-?\s*out|sign\s*-?\s*out|logout|signout|delete|destroy|remove/i

const outDir = process.argv[2]
const input = JSON.parse(await readStdin())
const passwords = input.roles.map((role) => role.password).filter(Boolean)

try {
  const summary = await crawlAll()
  await fs.writeFile(path.join(outDir, "crawl.json"), JSON.stringify(summary, null, 2))
  process.exit(summary.roles.some((role) => role.ok) ? 0 : 2)
} catch (error) {
  process.stderr.write(`${safe(error)}\n`)
  process.exit(1)
}

async function crawlAll() {
  const base = new URL(input.baseUrl)
  const maxPages = input.maxPagesPerRole || 40
  const colours = new Map()
  const fonts = new Set()
  const browser = await chromium.launch()
  const roles = []
  try {
    for (const [index, role] of input.roles.entries()) {
      const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
      const page = await context.newPage()
      const entry = { name: role.name, ok: false, pages: [] }
      try {
        await logIn(page, role)
        entry.ok = true
        await crawlRole(page, base, maxPages, folderFor(role, index), entry, colours, fonts)
      } catch (error) {
        entry.error = safe(error)
      } finally {
        await context.close()
      }
      roles.push(entry)
    }
  } finally {
    await browser.close()
  }
  const topColours = [...colours].sort((a, b) => b[1] - a[1]).slice(0, 24).map(([colour]) => colour)
  return { roles, styles: { colors: topColours, fonts: [...fonts] } }
}

// The first e-mail or text field takes the username, the first password field
// the password, and the form is submitted. Logged in means the browser left
// the login page and shows no password field.
async function logIn(page, role) {
  const login = new URL(role.loginUrl)
  await page.goto(login.href, { waitUntil: "load" })
  const user = page.locator('input[type=email], input[name*=email i], input[type=text]').first()
  const password = page.locator("input[type=password]").first()
  await user.fill(role.username)
  await password.fill(role.password)
  await Promise.all([
    page.waitForURL((url) => url.pathname !== login.pathname, { timeout: 15_000 }).catch(() => {}),
    password.evaluate((field) => (field.form ? field.form.requestSubmit() : null)),
  ])
  await page.waitForLoadState("load")
  const stillHere = new URL(page.url()).pathname === login.pathname
  const passwordShown = await page.locator("input[type=password]").first().isVisible().catch(() => false)
  if (stillHere || passwordShown) throw new Error("login failed (still on the login page)")
}

async function crawlRole(page, base, maxPages, folder, entry, colours, fonts) {
  const dir = path.join(outDir, "pages", folder)
  await fs.mkdir(dir, { recursive: true })
  const queue = [base.href]
  const seen = new Set()
  while (queue.length && entry.pages.length < maxPages) {
    const next = queue.shift()
    if (seen.has(next)) continue
    seen.add(next)
    try {
      await page.goto(next, { waitUntil: "load", timeout: 30_000 })
    } catch {
      continue
    }
    const here = new URL(page.url())
    if (here.origin !== base.origin) continue

    await page.evaluate(mask, passwords)
    const n = entry.pages.length + 1
    const screenshot = path.join("pages", folder, `${n}.png`)
    const dom = path.join("pages", folder, `${n}.html`)
    await page.screenshot({ path: path.join(outDir, screenshot), fullPage: true })
    await fs.writeFile(path.join(outDir, dom), await page.evaluate(snapshot))
    entry.pages.push({ url: here.href, title: await page.title(), screenshot, dom })

    const styles = await page.evaluate(sampleStyles)
    styles.colors.forEach((colour) => colours.set(colour, (colours.get(colour) || 0) + 1))
    styles.fonts.forEach((font) => fonts.add(font))
    for (const link of await page.evaluate(links, UNSAFE.source)) {
      const url = new URL(link)
      url.hash = ""
      if (url.origin === base.origin && !seen.has(url.href)) queue.push(url.href)
    }
  }
}

// In the page: empty every password field, and mask a password wherever else
// it shows (a profile form echoing it, say), in field values and in text.
function mask(secrets) {
  const hide = (text) => secrets.reduce((out, secret) => out.split(secret).join("••••••"), text)
  document.querySelectorAll("input[type=password]").forEach((field) => {
    field.value = ""
    field.removeAttribute("value")
  })
  document.querySelectorAll("input, textarea").forEach((field) => {
    if (secrets.some((secret) => field.value.includes(secret))) field.value = hide(field.value)
    const attribute = field.getAttribute("value")
    if (attribute && secrets.some((secret) => attribute.includes(secret))) field.setAttribute("value", hide(attribute))
  })
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (secrets.some((secret) => node.nodeValue.includes(secret))) node.nodeValue = hide(node.nodeValue)
  }
}

// In the page: the DOM as it stands, scripts removed.
function snapshot() {
  const copy = document.documentElement.cloneNode(true)
  copy.querySelectorAll("script, noscript").forEach((node) => node.remove())
  copy.querySelectorAll("input[type=password]").forEach((field) => field.removeAttribute("value"))
  return `<!doctype html>\n${copy.outerHTML}`
}

// In the page: links worth following. Not downloads, not links that send
// anything but GET (data-method, data-turbo-method), not ones that log out
// or delete, by text or address.
function links(unsafeSource) {
  const unsafe = new RegExp(unsafeSource, "i")
  return [...document.querySelectorAll("a[href]")]
    .filter((a) => !a.hasAttribute("download"))
    .filter((a) => {
      const method = (a.getAttribute("data-method") || a.getAttribute("data-turbo-method") || "get").toLowerCase()
      return method === "get"
    })
    .filter((a) => !unsafe.test(a.textContent || "") && !unsafe.test(a.getAttribute("href") || ""))
    .map((a) => a.href)
    .filter((href) => href.startsWith("http"))
}

// In the page: the colours and font families its elements are drawn with.
function sampleStyles() {
  const colors = []
  const fonts = new Set()
  const elements = [...document.querySelectorAll("body *")].slice(0, 2000)
  for (const element of elements) {
    const style = getComputedStyle(element)
    for (const value of [style.color, style.backgroundColor, style.borderTopColor]) {
      if (value && value !== "rgba(0, 0, 0, 0)" && value !== "transparent") colors.push(value)
    }
    style.fontFamily.split(",").forEach((family) => fonts.add(family.trim().replace(/^["']|["']$/g, "")))
  }
  return { colors, fonts: [...fonts] }
}

function folderFor(role, index) {
  const name = String(role.name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
  return `${index + 1}-${name || "role"}`
}

// An error's message with every password masked: Playwright repeats what it
// was asked to type in some of its errors.
function safe(error) {
  const message = String((error && error.message) || error).split("\n")[0]
  return passwords.reduce((out, secret) => out.split(secret).join(MASK), message)
}

async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  return Buffer.concat(chunks).toString("utf8")
}
