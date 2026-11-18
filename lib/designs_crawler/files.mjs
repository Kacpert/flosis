// copy_file for a design thread's turn (Kacper, 2026-11-19): an MCP server on
// stdio, flosis_files, that copies one file of the design repo to a new path
// in it, so a new screen starts from the closest one and is edited, instead of
// being written out from scratch. FLOSIS_FILES_ROOT names the repo (the turn's
// worktree); nothing outside it is read or written (files_lib.mjs).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"
import { copyWithin } from "./files_lib.mjs"

const server = new McpServer({ name: "flosis_files", version: "1.0.0" })

server.registerTool("copy_file", {
  description: "Copy a file of the design repo to a new path in it. Both paths are relative to the repo, " +
    "e.g. designs/admin/consumption.html. The new path must not exist yet. Use it to start a new screen " +
    "from the closest existing one, then edit the copy with Edit.",
  inputSchema: { from: z.string(), to: z.string() }
}, async ({ from, to }) => {
  try {
    const bytes = await copyWithin(process.env.FLOSIS_FILES_ROOT, from, to)
    return { content: [ { type: "text", text: `Copied ${from} to ${to} (${bytes} bytes). Edit the copy for what differs.` } ] }
  } catch (error) {
    return { content: [ { type: "text", text: `Error: ${String(error.message || error).split("\n")[0]}` } ], isError: true }
  }
})

await server.connect(new StdioServerTransport())
