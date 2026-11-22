// What flosis_git lets Claude run on the app's history (Kacper, 2026-11-22):
// read-only subcommands, with the flags that keep drivers off, and nothing
// that writes a file, reads one outside the repository or runs a program,
// in any spelling git would take.
import { test } from "node:test"
import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { answer, cap, checkArgs, gitArgv, gitEnv } from "../git_lib.mjs"

test("allows read-only subcommands and adds the safe flags", () => {
  assert.deepEqual(checkArgs([ "diff", "a..b", "--", "config/routes.rb" ]).args,
                   [ "diff", "--no-ext-diff", "--no-textconv", "a..b", "--", "config/routes.rb" ])
  assert.deepEqual(checkArgs([ "grep", "-n", "resources", "HEAD" ]).args, [ "grep", "--no-textconv", "-n", "resources", "HEAD" ])
  for (const ok of [ [ "log", "--oneline", "-n", "20" ], [ "log", "-5" ], [ "show", "HEAD:config/routes.rb" ], [ "blame", "-L", "1,20", "HEAD", "--", "x" ],
                     [ "ls-tree", "-r", "--name-only", "HEAD" ], [ "rev-list", "--count", "a..b" ], [ "log", "-S", "Object" ] ]) {
    assert.equal(checkArgs(ok).ok, true, ok.join(" "))
  }
})

test("refuses subcommands that change anything or reach the network", () => {
  for (const sub of [ "push", "fetch", "pull", "checkout", "branch", "tag", "config", "gc", "update-ref", "archive", "format-patch", "clone", "remote" ]) {
    assert.equal(checkArgs([ sub ]).ok, false, sub)
  }
  assert.equal(checkArgs([]).ok, false)
})

test("refuses options that write, read outside the history or run programs, in every spelling", () => {
  for (const bad of [ [ "diff", "--output=x" ], [ "diff", "--output", "x" ], [ "diff", "--outp=x" ], [ "diff", "--ext-diff" ],
                      [ "diff", "--no-index", "/etc/passwd", "x" ], [ "blame", "--contents", "/etc/passwd", "f" ], [ "blame", "-S", "revs", "f" ],
                      [ "blame", "-wS", "revs" ], [ "blame", "--ignore-revs-file=x", "f" ], [ "grep", "-f", "/etc/passwd" ], [ "grep", "--file=/x" ],
                      [ "grep", "-Ovim", "x" ], [ "grep", "-iO", "x" ], [ "grep", "--open-files-in-pager", "x" ], [ "log", "-O/etc/order" ],
                      [ "log", "--git-dir=/x" ], [ "show", "--textconv", "HEAD" ], [ "cat-file", "--filters", "HEAD:x" ], [ "log", "--paginate" ] ]) {
    assert.equal(checkArgs(bad).ok, false, bad.join(" "))
  }
})

// Final review C1 (2026-11-22): a bare clone diffs any two paths outside it
// as files, so no argument may name a path outside the history, and a "--"
// taken as an option's value must not hide the options after it.
test("refuses any path outside the history, before or after --", () => {
  for (const bad of [ [ "diff", "/dev/null", "/home/x/.env" ], [ "diff", "--", "/dev/null", "/home/x/.env" ],
                      [ "diff", "/dev/null", "../../secret" ], [ "log", "--", "../x" ], [ "show", "HEAD:../x" ], [ "diff", "~/x", "y" ],
                      [ "grep", "-e", "--", "-f", "/etc/passwd" ], [ "log", "--grep", "--", "--output=x" ] ]) {
    assert.equal(checkArgs(bad).ok, false, bad.join(" "))
  }
  for (const ok of [ [ "diff", "a1b2c3d..HEAD", "--", "config/routes.rb" ], [ "log", "--stat", "abc..def" ], [ "log", "HEAD..", "--", "app/" ] ]) {
    assert.equal(checkArgs(ok).ok, true, ok.join(" "))
  }
})

test("cuts what is too long with a note", () => {
  assert.match(cap("x".repeat(200), 100), /\n… \(cut at 100 bytes: narrow it with a path, a range or --stat\)$/)
  assert.equal(cap("short", 100), "short")
  assert.doesNotMatch(cap("ż".repeat(100), 101), /�/)
})

test("runs git with no user or system config, no pager and no abbreviations", () => {
  const env = gitEnv("/tmp/empty")
  assert.equal(env.GIT_CONFIG_NOSYSTEM, "1")
  assert.equal(env.GIT_CONFIG_GLOBAL, "/dev/null")
  assert.equal(env.HOME, "/tmp/empty")
  assert.equal(env.GIT_PAGER, "cat")
  assert.equal(env.GIT_TERMINAL_PROMPT, "0")
  assert.equal(env.GIT_TEST_DISALLOW_ABBREVIATED_OPTIONS, "true")
  assert.equal(Object.keys(env).includes("FLOSIS_GIT_REPOS"), false)
  assert.deepEqual(gitArgv("/r.git", [ "log" ]).slice(-3), [ "--git-dir", "/r.git", "log" ])
})

// Kacper, 2026-11-22 ("grep bez trafień zwraca komunikat błędu ... to dobrze
// czy źle?"): git grep exits 1 when nothing matches, and so does
// merge-base --is-ancestor when it is not one. That exit is an answer, not
// an error, and no answer carries the command line with the clone's path.
const exited = (code, stderr = "") => ({ stdout: "", stderr,
  error: Object.assign(new Error("Command failed: git --git-dir /srv/app-history/acme-app.git grep x HEAD"), { code, killed: false, signal: null }) })

test("grep finding nothing answers No matches, not an error", () => {
  assert.deepEqual(answer("grep", exited(1)), { text: "No matches.", isError: false })
  assert.deepEqual(answer("merge-base", exited(1)), { text: "(no output; git exited with code 1)", isError: false })
})

test("an error is git's own message, never the command line with the clone's path", () => {
  assert.deepEqual(answer("log", exited(128, "fatal: bad revision 'x'\n")), { text: "Error: fatal: bad revision 'x'", isError: true })
  const silent = answer("log", exited(128))
  assert.equal(silent.isError, true)
  assert.match(silent.text, /^Error: git log failed with exit code 128\.$/)
  assert.doesNotMatch(silent.text, /app-history|--git-dir/)
})

// The same day ("wynik ucięty po 30 s nie ma dopisku"): a run stopped at the
// time limit says that what it gives is only a part. The run is a real one
// stopped by execFile's own timeout, so the error is the one git.mjs meets.
test("a run stopped at the time limit says its output is only a part", async () => {
  const run = await new Promise((resolve) => execFile(process.execPath, [ "-e", "process.stdout.write('a1b2c3d Routes\\n'); setTimeout(() => {}, 10000)" ],
                                                      { timeout: 300 }, (error, stdout, stderr) => resolve({ error, stdout, stderr })))
  const partial = answer("log", run)
  assert.equal(partial.isError, false)
  assert.match(partial.text, /^a1b2c3d Routes\n… \(git was stopped after 30 s, so this is only part of the output: narrow it with a path, a range or -n\)$/)

  const nothing = answer("log", { ...run, stdout: "" })
  assert.equal(nothing.isError, true)
  assert.match(nothing.text, /^Error: git was stopped after 30 s before it gave anything: narrow it with a path, a range or -n\.$/)
})

test("a long answer is cut with its note, and an empty one says so", () => {
  const long = answer("log", { error: null, stdout: "x".repeat(200), stderr: "" }, 100)
  assert.match(long.text, /\(cut at 100 bytes/)
  assert.deepEqual(answer("log", { error: null, stdout: "", stderr: "" }), { text: "(no output)", isError: false })
})
