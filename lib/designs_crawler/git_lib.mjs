// What flosis_git (git.mjs) lets Claude run on the app's history (Kacper,
// 2026-11-22: "dobrze żeby miał po prostu dostęp do gita ... w ten sposób ma
// wszystko"): read-only git, on the project's own bare clones, and nothing
// that writes a file, reads one outside the repository or runs a program.
// Turns have no shell (they run --restricted on a host shared with other
// sites), so this is the only git they get.

// The subcommands that only read the repository.
export const ALLOWED = [ "log", "show", "diff", "blame", "grep", "ls-tree", "rev-parse", "rev-list", "shortlog", "cat-file",
                         "merge-base", "diff-tree", "for-each-ref", "describe", "name-rev" ]

// Long options refused wherever they come: they write a file (--output),
// read one outside the repository (--no-index, --contents,
// --ignore-revs-file), run a program (--ext-diff, --textconv, --filters,
// --open-files-in-pager, --exec, --upload-pack) or point git elsewhere.
const REFUSED = [ "--output", "--ext-diff", "--textconv", "--filters", "--filter", "--no-index", "--contents", "--ignore-revs-file",
                  "--open-files-in-pager", "--exec", "--exec-path", "--upload-pack", "--config-env", "--git-dir", "--work-tree",
                  "--namespace", "--paginate", "--super-prefix", "--orderfile" ]
// Per subcommand: grep reads patterns from a file (-f, --file); blame reads
// revisions from one (-S).
const REFUSED_FOR = { grep: { long: [ "--file" ], short: [ "f" ] }, blame: { long: [], short: [ "S" ] } }
// -O opens files in a pager (grep) or reads an order file (diff, log, show).
const REFUSED_SHORT = [ "O" ]
// Always on, so that no driver or filter runs: diff-like output never goes
// through an external diff or a textconv filter.
const FORCED = { diff: [ "--no-ext-diff", "--no-textconv" ], show: [ "--no-ext-diff", "--no-textconv" ],
                 log: [ "--no-ext-diff", "--no-textconv" ], "diff-tree": [ "--no-ext-diff", "--no-textconv" ],
                 grep: [ "--no-textconv" ] }

export const LIMIT = 100_000
export const TIMEOUT = 30_000
const MAX_ARGS = 64
const MAX_ARG = 1_000

// { ok: true, args } with the forced flags right after the subcommand, or
// { ok: false, error }. Every argument is checked, after "--" too: an
// option's value may be "--" itself (grep -e -- -f file), and a bare clone
// diffs any two paths outside it as plain files (final review C1,
// 2026-11-22), so no argument may name a path outside the history.
export function checkArgs(args) {
  if (!Array.isArray(args) || args.length === 0) return refuse("Give a git subcommand and its arguments, such as [\"log\", \"--oneline\", \"-n\", \"20\"].")
  if (args.length > MAX_ARGS || args.some((arg) => typeof arg !== "string" || arg.length > MAX_ARG || arg.includes("\0"))) {
    return refuse(`At most ${MAX_ARGS} arguments, each a string of at most ${MAX_ARG} characters.`)
  }
  const [ sub, ...rest ] = args
  if (!ALLOWED.includes(sub)) return refuse(`git ${sub} is not allowed here: only ${ALLOWED.join(", ")}, which only read the history.`)

  const long = REFUSED.concat(REFUSED_FOR[sub]?.long || [])
  const short = REFUSED_SHORT.concat(REFUSED_FOR[sub]?.short || [])
  for (const arg of rest) {
    if (arg === "--") continue
    if (outside(arg)) return refuse(`${arg} is outside the history: name paths inside the repository, such as config/routes.rb.`)
    if (arg.startsWith("--")) {
      const name = arg.split("=")[0]
      // A refused option, or an abbreviation git might take for one.
      if (name.length > 2 && long.some((refused) => name.startsWith(refused) || refused.startsWith(name))) {
        return refuse(`${name} is not allowed here: it would write or read files outside the history, or run a program.`)
      }
    } else if (arg.startsWith("-") && arg.length > 1 && !/^-\d+$/.test(arg)) {
      // A cluster of short options, such as -iO: the letters up to the first
      // one that takes a value are flags; refuse if a refused one is among
      // them, wherever it is.
      const letters = arg.slice(1)
      const hit = short.find((letter) => letters.includes(letter))
      if (hit) return refuse(`-${hit} is not allowed here: it would read a file or run a program.`)
    }
  }
  return { ok: true, args: [ sub, ...(FORCED[sub] || []), ...rest ] }
}

// The text, cut at limit bytes (on a character's boundary) with a note that
// says how to see the rest.
export function cap(text, limit = LIMIT) {
  const bytes = Buffer.from(String(text), "utf8")
  if (bytes.length <= limit) return String(text)

  const cut = bytes.subarray(0, limit).toString("utf8").replace(/�$/, "")
  return `${cut}\n… (cut at ${limit} bytes: narrow it with a path, a range or --stat)`
}

// The environment git runs in: only PATH from ours, an empty HOME, no system
// or global config, no pager, no prompt, no abbreviated options.
export function gitEnv(home) {
  return { PATH: process.env.PATH || "/usr/bin:/bin", HOME: home, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
           GIT_PAGER: "cat", PAGER: "cat", GIT_TERMINAL_PROMPT: "0", GIT_ATTR_NOSYSTEM: "1", GIT_NO_REPLACE_OBJECTS: "1",
           GIT_OPTIONAL_LOCKS: "0", GIT_TEST_DISALLOW_ABBREVIATED_OPTIONS: "true" }
}

// The command line: config that keeps hooks and the network off, the clone,
// and the checked arguments.
export function gitArgv(gitDir, args) {
  return [ "--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never", "-c", "core.fsmonitor=false",
           "-c", "diff.external=", "--git-dir", gitDir, ...args ]
}

// A path that leaves the repository: absolute, from a home folder, or with a
// ".." segment (after a revision's ":" too). A range such as a..b is not one.
function outside(arg) {
  return arg.startsWith("/") || arg.startsWith("~") || /(^|[/:])\.\.(\/|$)/.test(arg)
}

function refuse(error) {
  return { ok: false, error }
}
