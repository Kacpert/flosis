// The setup's sign-in and browser tools against a small app served here: the
// sign-in leaves a private state and never the password, and the browser
// keeps to the test environment, never signs out, fills forms without
// passwords, and reports on the designs it serves from a worktree.
import { test, before, after } from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import fs from "node:fs/promises"
import http from "node:http"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { chromium } from "playwright"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"

const here = path.dirname(fileURLToPath(import.meta.url))
const PASSWORD = "secret-pass-4711"
const requests = []
let server, base, other, tmp, client, canLaunch = true

const page = (title, body) => `<!doctype html><html><head><title>${title}</title></head><body>${body}</body></html>`

function app(req, res) {
  const url = new URL(req.url, base)
  let body = ""
  req.on("data", (chunk) => (body += chunk))
  req.on("end", () => {
    requests.push({ method: req.method, path: url.pathname, body })
    const signedIn = (req.headers.cookie || "").includes("sid=ok")
    const send = (status, html, headers = {}) => res.writeHead(status, { "content-type": "text/html", ...headers }).end(html)
    if (url.pathname === "/login" && req.method === "GET") {
      return send(200, page("Sign in", `<form method="post" action="/login"><label>E-mail <input type="email" name="email"></label>
        <label>Password <input type="password" name="password"></label><button>Sign in</button></form>`))
    }
    if (url.pathname === "/login") {
      const ok = new URLSearchParams(body).get("password") === PASSWORD
      return ok ? send(303, "", { location: "/", "set-cookie": "sid=ok; Path=/" }) : send(303, "", { location: "/login" })
    }
    if (!signedIn) return send(303, "", { location: "/login" })
    if (url.pathname === "/") {
      return send(200, page("Home", `<h1>Home</h1><a href="/projects/new">New project</a> <a href="/logout">Sign out</a>
        <a href="${other}/">Elsewhere</a> <a href="${other}/" target="_blank">Elsewhere in a tab</a> <a href="/away">Away</a>`))
    }
    if (url.pathname === "/away") return send(302, "", { location: `${other}/` })
    if (url.pathname === "/projects/new") {
      return send(200, page("New project", `<form method="post" action="/projects">
        <label for="n">Name</label><input id="n" name="project[name]" required>
        <label for="e">Owner e-mail</label><input id="e" type="email" name="project[email]">
        <label for="p">Password</label><input id="p" type="password" name="project[password]">
        <label for="c">Country</label><select id="c" name="project[country]"><option value="">Pick one</option><option value="pl">Poland</option></select>
        <label><input type="checkbox" name="project[terms]" required> I agree</label>
        <button type="submit">Create project</button></form>`))
    }
    if (url.pathname === "/projects" && req.method === "POST") return send(303, "", { location: "/projects" })
    if (url.pathname === "/projects") return send(200, page("Projects", "<h1>Projects</h1>"))
    return send(404, page("Not found", "Not found"))
  })
}

async function signIn(outDir, roles) {
  const child = spawn("node", [ path.join(here, "..", "sign_in.mjs"), outDir ], { cwd: path.join(here, "..") })
  let out = ""
  child.stdout.on("data", (chunk) => (out += chunk))
  child.stdin.end(JSON.stringify({ roles }))
  const code = await new Promise((resolve) => child.on("close", resolve))
  return { code, out: out ? JSON.parse(out) : null }
}

const text = (result) => result.content.filter((part) => part.type === "text").map((part) => part.text).join("\n")
const refOf = (state, label) => state.match(new RegExp(`\\[(e\\d+)\\][^\\n]*"${label}"`))?.[1]
const call = (name, args) => client.callTool({ name, arguments: args })

before(async () => {
  try {
    const browser = await chromium.launch()
    await browser.close()
  } catch {
    canLaunch = false
    return
  }
  server = http.createServer(app)
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  base = `http://127.0.0.1:${server.address().port}`
  other = `http://localhost:${server.address().port}`
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), "flosis-browser-"))
  await fs.mkdir(path.join(tmp, "worktree", "designs", "admin"), { recursive: true })
  await fs.writeFile(path.join(tmp, "worktree", "designs", "admin", "home.html"), page("Home design",
    `<h1>Home</h1><a href="home.html">Home</a> <a href="missing.html">Missing</a><script>console.error("boom")</script>`))
})

after(async () => {
  await client?.close()
  server?.close()
  if (tmp) await fs.rm(tmp, { recursive: true, force: true })
})

test("sign-in, then the browser tools", async (t) => {
  if (!canLaunch) return t.skip("Chromium cannot be launched here")

  const auth = path.join(tmp, "auth")
  const signedIn = await signIn(auth, [
    { slug: "1-admin", name: "Admin", loginUrl: `${base}/login`, username: "admin@example.test", password: PASSWORD },
    { slug: "2-member", name: "Member", loginUrl: `${base}/login`, username: "member@example.test", password: "wrong" },
  ])
  assert.equal(signedIn.code, 0)
  assert.deepEqual(signedIn.out.roles.map((role) => [ role.slug, role.ok ]), [ [ "1-admin", true ], [ "2-member", false ] ])
  const state = path.join(auth, "1-admin.json")
  assert.equal((await fs.stat(state)).mode & 0o777, 0o600)
  assert.equal((await fs.stat(auth)).mode & 0o777, 0o700)
  assert.doesNotMatch(await fs.readFile(state, "utf8"), new RegExp(PASSWORD))
  assert.doesNotMatch(JSON.stringify(signedIn.out), new RegExp(PASSWORD))

  const config = path.join(tmp, "browser.json")
  await fs.writeFile(config, JSON.stringify({
    baseUrl: base, contexts: [ { slug: "1-admin", name: "Admin", statePath: state } ],
    worktree: path.join(tmp, "worktree"), progressPath: path.join(tmp, "progress.json"),
    featuresPath: path.join(tmp, "features.json"), featureKey: "home", viewport: { width: 1280, height: 800 },
  }))
  client = new Client({ name: "browser-test", version: "1.0.0" })
  await client.connect(new StdioClientTransport({ command: "node", args: [ path.join(here, "..", "browser.mjs") ],
                                                  env: { ...process.env, FLOSIS_BROWSER_CONFIG: config } }))
  const tools = (await client.listTools()).tools.map((tool) => tool.name).sort()
  assert.deepEqual(tools, [ "check_design", "click", "compare", "design", "fill_form", "open", "progress", "save_features", "screenshot" ])

  const home = text(await call("open", { context: "1-admin", path: "/" }))
  assert.match(home, /Home/)

  const signOut = text(await call("click", { context: "1-admin", ref: refOf(home, "Sign out") }))
  assert.match(signOut, /Not allowed/)
  assert.equal(requests.some((request) => request.path === "/logout"), false, "the sign-out link was never followed")

  for (const label of [ "Elsewhere", "Elsewhere in a tab", "Away" ]) {
    const fresh = text(await call("open", { context: "1-admin", path: "/" }))
    const result = text(await call("click", { context: "1-admin", ref: refOf(fresh, label) }))
    assert.match(result, /Not allowed: that leaves the test environment/, label)
    assert.match(result, new RegExp(`URL: /`), label)
  }

  const form = text(await call("open", { context: "1-admin", path: "/projects/new" }))
  assert.match(form, /textbox "Name"/)
  const filled = text(await call("fill_form", { context: "1-admin" }))
  assert.match(filled, /Owner e-mail = [^\n]*@example\.test/)
  assert.match(filled, /Country = pl/)
  assert.match(filled, /Password: left empty/)
  await call("fill_form", { context: "1-admin", values: { name: "Acme", password: "not-this" }, submit: true })
  const posted = requests.findLast((request) => request.method === "POST" && request.path === "/projects")
  const params = new URLSearchParams(posted.body)
  assert.equal(params.get("project[name]"), "Acme")
  assert.equal(params.get("project[password]"), "")
  assert.match(params.get("project[email]"), /@example\.test$/)
  assert.equal(params.get("project[terms]"), "on")

  await call("progress", { screen: "Home", status: "checking" })
  await call("progress", { screen: "Home", status: "done" })
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(tmp, "progress.json"), "utf8")), { feature: "home", screens: { Home: "done" } })

  await call("save_features", { features: [ { name: "Home", contexts: [ "1-admin" ], screens: [ "Home" ], brief: "The home page.", notes: [] } ] })
  assert.equal(JSON.parse(await fs.readFile(path.join(tmp, "features.json"), "utf8"))[0].name, "Home")

  const design = text(await call("design", { path: "designs/admin/home.html" }))
  assert.match(design, /boom/)
  const check = text(await call("check_design", { path: "designs/admin/home.html" }))
  assert.match(check, /missing\.html/)
  assert.doesNotMatch(check.split("\n").find((line) => line.includes("do not exist")) || "", /home\.html/)

  const shot = await call("screenshot", { context: "1-admin" })
  assert.equal(shot.content[0].type, "image")
  const compared = await call("compare", { context: "1-admin", app_path: "/", design_path: "designs/admin/home.html" })
  assert.equal(compared.content.filter((part) => part.type === "image").length, 2)

  const outside = text(await call("design", { path: "../browser.json" }))
  assert.match(outside, /Not allowed/)
})
