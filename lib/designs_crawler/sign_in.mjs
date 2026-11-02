// Signs in to a setup run's test environment as each of its contexts, and
// leaves each one's browser state (its cookies and storage) in a file of its
// own, for the setup's browser (browser.mjs) to start from. So the browser,
// and the Claude that drives it, never see a password.
//
//   node sign_in.mjs <outDir>   (input as JSON on stdin)
//   { "roles": [{ "slug", "name", "loginUrl", "username", "password" }] }
//
// Passwords arrive on stdin only, and nothing here prints them: an error is
// masked before it is said. Each state is <outDir>/<slug>.json, 0600, in a
// 0700 folder. It prints { "roles": [{ "slug", "ok", "error" }] } and exits
// 0 when at least one context signed in, 2 when none did, 1 on anything else.
import { chromium } from "playwright"
import fs from "node:fs/promises"
import path from "node:path"
import { logIn, safe } from "./login.mjs"

const outDir = process.argv[2]
const input = JSON.parse(await readStdin())
const secrets = input.roles.map((role) => role.password).filter(Boolean)

try {
  await fs.mkdir(outDir, { recursive: true, mode: 0o700 })
  await fs.chmod(outDir, 0o700)
  const roles = await signInAll()
  process.stdout.write(JSON.stringify({ roles }))
  process.exit(roles.some((role) => role.ok) ? 0 : 2)
} catch (error) {
  process.stderr.write(`${safe(error, secrets)}\n`)
  process.exit(1)
}

async function signInAll() {
  const browser = await chromium.launch()
  const roles = []
  try {
    for (const role of input.roles) {
      const context = await browser.newContext({ viewport: { width: 1440, height: 900 } })
      try {
        await logIn(await context.newPage(), role)
        const file = path.join(outDir, `${role.slug}.json`)
        await context.storageState({ path: file })
        await fs.chmod(file, 0o600)
        roles.push({ slug: role.slug, ok: true })
      } catch (error) {
        roles.push({ slug: role.slug, ok: false, error: safe(error, secrets) })
      } finally {
        await context.close()
      }
    }
  } finally {
    await browser.close()
  }
  return roles
}

async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  return Buffer.concat(chunks).toString("utf8")
}
