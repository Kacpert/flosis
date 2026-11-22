// What flosis_git lets Claude run on the app's history (Kacper, 2026-11-22):
// read-only subcommands, with the flags that keep drivers off, and nothing
// that writes a file, reads one outside the repository or runs a program,
// in any spelling git would take.
import { test } from "node:test"
import assert from "node:assert/strict"
import { cap, checkArgs, gitArgv, gitEnv } from "../git_lib.mjs"

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
