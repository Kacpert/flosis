// suggest on flosis_browser (Kacper, 2026-11-22): a turn leaves, for the
// person, what only they can give (a role the contexts lack, data the test
// environment has none of), one JSON line each, and goes on. No browser
// starts for it.
import { test, before, after } from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"

const here = path.dirname(fileURLToPath(import.meta.url))
let tmp, client, file

before(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), "flosis-suggest-"))
  file = path.join(tmp, "suggestions.jsonl")
  const config = path.join(tmp, "browser.json")
  await fs.writeFile(config, JSON.stringify({ baseUrl: "http://127.0.0.1:9", contexts: [], worktree: tmp,
                                              progressPath: path.join(tmp, "progress.json"), suggestionsPath: file }))
  client = new Client({ name: "suggest-test", version: "1.0.0" })
  await client.connect(new StdioClientTransport({ command: "node", args: [ path.join(here, "..", "browser.mjs") ],
                                                  env: { ...process.env, FLOSIS_BROWSER_CONFIG: config } }))
})

after(async () => {
  await client?.close()
  await fs.rm(tmp, { recursive: true, force: true })
})

test("suggest leaves one line for the person per thing", async () => {
  const tools = (await client.listTools()).tools.map((tool) => tool.name)
  assert.ok(tools.includes("suggest"))

  const said = await client.callTool({ name: "suggest", arguments: { kind: "context", title: "Flosis staff can see the Library",
                                                                     context: "Flosis staff", features: [ "library" ] } })
  assert.match(said.content[0].text, /Noted for the person/)
  await client.callTool({ name: "suggest", arguments: { kind: "other", title: "No invoices on staging", detail: "The list is empty." } })

  const lines = (await fs.readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line))
  assert.deepEqual(lines.map((line) => line.kind), [ "context", "other" ])
  assert.deepEqual([ lines[0].context, lines[0].features ], [ "Flosis staff", [ "library" ] ])
  assert.equal(lines[1].detail, "The list is empty.")
})

test("an unknown kind is refused", async () => {
  const result = await client.callTool({ name: "suggest", arguments: { kind: "password", title: "Give me the password" } })
    .catch((error) => ({ isError: true, content: [ { text: String(error) } ] }))
  assert.equal(result.isError, true)
})
