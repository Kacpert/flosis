// flosis_git as Claude meets it: the git tool on a bare clone of the app,
// answering a log and a diff, and refusing what it may not run.
import { test, before, after } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"

const here = path.dirname(fileURLToPath(import.meta.url))
let tmp, client, first

const git = (cwd, ...args) => execFileSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@example.test", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@example.test" } }).trim()
const call = async (args, repo = "acme/app") => {
  const result = await client.callTool({ name: "git", arguments: { repo, args } })
  return { text: result.content[0].text, error: !!result.isError }
}

before(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), "flosis-git-test-"))
  const work = path.join(tmp, "work")
  await fs.mkdir(path.join(work, "config"), { recursive: true })
  git(tmp, "init", "-q", "-b", "main", work)
  await fs.writeFile(path.join(work, "config/routes.rb"), "resources :bugs\n")
  git(work, "add", ".")
  git(work, "commit", "-qm", "Bugs")
  first = git(work, "rev-parse", "HEAD")
  await fs.writeFile(path.join(work, "config/routes.rb"), "resources :bugs\nresources :releases\n")
  git(work, "commit", "-qam", "Release notes")
  git(tmp, "clone", "-q", "--bare", work, path.join(tmp, "app.git"))

  client = new Client({ name: "git-test", version: "1.0.0" })
  await client.connect(new StdioClientTransport({ command: "node", args: [ path.join(here, "..", "git.mjs") ],
                                                  env: { ...process.env, FLOSIS_GIT_REPOS: JSON.stringify({ "acme/app": path.join(tmp, "app.git") }) } }))
})

after(async () => {
  await client?.close()
  await fs.rm(tmp, { recursive: true, force: true })
})

test("reads the history: a log and a diff since a commit", async () => {
  const log = await call([ "log", "--oneline" ])
  assert.equal(log.error, false)
  assert.match(log.text, /Release notes/)
  assert.match(log.text, /Bugs/)

  const diff = await call([ "diff", first, "HEAD", "--", "config/routes.rb" ])
  assert.match(diff.text, /\+resources :releases/)
})

test("refuses what it may not run, and an unknown repository", async () => {
  const push = await call([ "push", "origin", "main" ])
  assert.equal(push.error, true)
  assert.match(push.text, /not allowed/)

  const output = await call([ "diff", "--output=/tmp/flosis-leak", first, "HEAD" ])
  assert.equal(output.error, true)

  const other = await call([ "log" ], "acme/other")
  assert.equal(other.error, true)
})

test("never reads a file outside the history", async () => {
  const secret = path.join(tmp, "secret.txt")
  await fs.writeFile(secret, "TOP-SECRET\n")
  for (const args of [ [ "diff", "/dev/null", secret ], [ "diff", "--", "/dev/null", secret ] ]) {
    const result = await call(args)
    assert.equal(result.error, true, args.join(" "))
    assert.doesNotMatch(result.text, /TOP-SECRET/)
  }
})

test("a git error is told, not thrown", async () => {
  const missing = await call([ "show", "no-such-commit" ])
  assert.equal(missing.error, true)
  assert.match(missing.text, /no-such-commit|unknown revision|bad revision/)
})

// Kacper, 2026-11-22: a grep that finds nothing is an answer, not an error.
test("grep finding nothing says so, and finds what is there", async () => {
  assert.deepEqual(await call([ "grep", "no-such-word", "HEAD" ]), { text: "No matches.", error: false })
  const found = await call([ "grep", "-n", "releases", "HEAD" ])
  assert.equal(found.error, false)
  assert.match(found.text, /HEAD:config\/routes\.rb:2:resources :releases/)
})
