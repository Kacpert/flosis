// The one thing flosis_files does, kept apart from the MCP server for its tests.
import { constants } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"

export const COPY_LIMIT = 2 * 1024 * 1024

// Copies root/from to root/to and returns the bytes copied. Both paths are
// relative and stay inside root: neither is, nor goes through, a link, and
// neither touches .git. from is a file of at most COPY_LIMIT bytes; to does
// not exist yet (an existing file is edited, not overwritten), its folder is
// made when missing.
export async function copyWithin(root, from, to) {
  if (!root) throw new Error("There is no design repo to copy in.")
  const base = await fs.realpath(root)

  const inside = async (relative, mustExist) => {
    if (typeof relative !== "string" || !relative.trim() || path.isAbsolute(relative)) {
      throw new Error(`${relative} must be a path relative to the design repo.`)
    }
    const full = path.resolve(base, relative)
    if (!full.startsWith(base + path.sep)) throw new Error(`${relative} is outside the design repo.`)
    const parts = path.relative(base, full).split(path.sep)
    if (parts.includes(".git")) throw new Error(`${relative} is in .git.`)

    let at = base
    for (const part of parts) {
      at = path.join(at, part)
      let stat
      try {
        stat = await fs.lstat(at)
      } catch (error) {
        if (error.code !== "ENOENT") throw error
        if (mustExist) throw new Error(`${relative} does not exist.`)
        break
      }
      if (stat.isSymbolicLink()) throw new Error(`${relative} goes through a link.`)
    }
    return full
  }

  const source = await inside(from, true)
  const target = await inside(to, false)
  const stat = await fs.stat(source)
  if (!stat.isFile()) throw new Error(`${from} is not a file.`)
  if (stat.size > COPY_LIMIT) throw new Error(`${from} is over 2 MB.`)
  const taken = await fs.lstat(target).then(() => true, (error) => {
    if (error.code === "ENOENT") return false
    throw error
  })
  if (taken) throw new Error(`${to} exists already: edit it instead.`)

  await fs.mkdir(path.dirname(target), { recursive: true })
  await fs.copyFile(source, target, constants.COPYFILE_EXCL)
  return stat.size
}
