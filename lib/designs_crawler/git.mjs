// The app's history for an import's turns (Kacper, 2026-11-22: "dobrze żeby
// miał po prostu dostęp do gita na środowisku i lokalnie pobranego projektu w
// ten sposób ma wszystko"): an MCP server on stdio, flosis_git, with one tool,
// git, that runs read-only git (git_lib.mjs) on the project's own bare clones
// of its app repositories (Designs::AppHistory). FLOSIS_GIT_REPOS names them,
// as JSON: { "owner/name": "/path/to/clone.git" }. The clones are full, so
// git never needs the network or a token here.
import { execFile } from "node:child_process"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"
import { LIMIT, TIMEOUT, cap, checkArgs, gitArgv, gitEnv } from "./git_lib.mjs"

const repos = JSON.parse(process.env.FLOSIS_GIT_REPOS || "{}")
const names = Object.keys(repos)
// An empty HOME of its own: no one's git config or credentials.
const home = await fs.mkdtemp(path.join(process.env.TMPDIR || os.tmpdir(), "flosis-git-"))

const server = new McpServer({ name: "flosis_git", version: "1.0.0" })

server.registerTool("git", {
  description: "Run read-only git on one of the app's repositories, with its whole history. args is the command after \"git\", " +
    "one argument a string, e.g. [\"log\", \"--stat\", \"a1b2c3d..HEAD\"], [\"diff\", \"a1b2c3d\", \"HEAD\", \"--\", \"config/routes.rb\"], " +
    `["show", "HEAD:app/views/layouts/application.html.erb"]. Allowed: log, show, diff, blame, grep, ls-tree, rev-parse, rev-list, ` +
    `shortlog, cat-file, merge-base, diff-tree, for-each-ref, describe, name-rev. Output past ${LIMIT} bytes is cut: narrow it with a path, a range or --stat.`,
  inputSchema: { repo: names.length ? z.enum(names).describe(`The repository: ${names.join(", ")}`) : z.string(),
                 args: z.array(z.string()).min(1).max(64) }
}, async ({ repo, args }) => {
  const gitDir = repos[repo]
  if (!gitDir) return failure(`No repository ${repo}: use one of ${names.join(", ") || "none"}.`)

  const checked = checkArgs(args)
  if (!checked.ok) return failure(checked.error)

  const { stdout, stderr, error } = await run(gitDir, checked.args)
  if (error && !stdout) return failure(cap(stderr.trim() || error.message, 4_000))

  const text = stdout || (stderr.trim() ? stderr : "(no output)")
  return { content: [ { type: "text", text: cap(text, LIMIT) } ] }
})

await server.connect(new StdioServerTransport())
process.stdin.on("close", shutdown)
process.on("SIGTERM", shutdown)

function run(gitDir, args) {
  return new Promise((resolve) => {
    const child = execFile("git", gitArgv(gitDir, args), { env: gitEnv(home), cwd: home, timeout: TIMEOUT, maxBuffer: 32 * 1024 * 1024 },
                           (error, stdout, stderr) => resolve({ error, stdout: String(stdout || ""), stderr: String(stderr || "") }))
    // Nothing comes on stdin: shortlog and cat-file --batch read it.
    child.stdin?.end()
  })
}

function failure(text) {
  return { content: [ { type: "text", text: `Error: ${text}` } ], isError: true }
}

async function shutdown() {
  await fs.rm(home, { recursive: true, force: true }).catch(() => {})
  process.exit(0)
}
