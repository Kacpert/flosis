import { test } from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { copyWithin } from "../files_lib.mjs"

async function repo() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "files-"))
  await fs.mkdir(path.join(root, "designs/admin"), { recursive: true })
  await fs.writeFile(path.join(root, "designs/admin/consumption.html"), "<title>Consumption</title>")
  return root
}

test("a screen is copied to a new path in the repo, its folder made", async () => {
  const root = await repo()
  const bytes = await copyWithin(root, "designs/admin/consumption.html", "designs/flosis-admin/plans.html")
  assert.equal(await fs.readFile(path.join(root, "designs/flosis-admin/plans.html"), "utf8"), "<title>Consumption</title>")
  assert.equal(bytes, 26)
})

test("nothing outside the repo, through a link, into .git, or over a file that exists", async () => {
  const root = await repo()
  const outside = await fs.mkdtemp(path.join(os.tmpdir(), "outside-"))
  await fs.writeFile(path.join(outside, "secret.txt"), "key")
  await fs.symlink(outside, path.join(root, "designs/linked"))
  const refused = (from, to, message) => assert.rejects(copyWithin(root, from, to), (error) => error.message.includes(message))
  await refused("/etc/hosts", "designs/a.html", "relative to the design repo")
  await refused("../secret.txt", "designs/a.html", "outside the design repo")
  await refused("designs/linked/secret.txt", "designs/a.html", "goes through a link")
  await refused("designs/admin/consumption.html", "designs/linked/a.html", "goes through a link")
  await refused("designs/admin/consumption.html", ".git/hooks/x", ".git")
  await refused("designs/admin/consumption.html", "designs/admin/consumption.html", "exists already")
  await refused("designs/admin/missing.html", "designs/admin/b.html", "does not exist")
})
