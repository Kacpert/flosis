require "fileutils"
require "securerandom"

# A project's design repo on disk, driven through GitRunner: one clone that
# stays on master, a worktree per working branch beside it, and one lock that
# every operation runs inside, so two jobs on one project (an initialization
# and a publish, say) never meet on git's own lock files.
#
# All of it lives in Project#designs_dir:
#   design-repo/        the clone, always on master
#   design-worktrees/   a folder per working branch, "wip/REC-1" in wip__REC-1
#   design-repo.lock    the lock
#
# The token reaches git only for what talks to GitHub (clone, fetch, push), and
# only through GitRunner's askpass: never in .git/config or in a remote URL.
class Designs::Repo
  MASTER = Designs::BranchNames::MASTER
  IDENTITY = { "user.name" => "Flosis", "user.email" => "designs@flosis.com" }.freeze

  # What the clone's own config always says, for its worktrees too: the
  # identity, so every commit and merge made here is Flosis's, and no symlinks.
  # A client can push one (designs/x.html pointing at the app's
  # .env.production); checked out as a link, Claude's tools would follow it
  # out of the checkout. With core.symlinks false it is a small plain file
  # holding the link's target.
  CONFIG = IDENTITY.merge("core.symlinks" => "false").freeze

  # Every master Flosis starts has the template's runtime from its first
  # commit, so a master without it is somebody else's repository.
  RUNTIME = "runtime/flosis.js".freeze

  # What a refused repo is told to do instead.
  REMEDY = "Create a new, empty repository (no README, licence or .gitignore).".freeze

  # How many of a refused repo's branches its error names. The error is stored
  # cut to 500 characters, and the remedy comes after the list.
  BRANCHES_NAMED = 10

  Change = Data.define(:path, :added_text)

  # The merge stopped on conflicting files. It has been aborted, so master is
  # where it was.
  class Conflict < StandardError; end

  # master already has everything on the branch. A merge would make no commit,
  # and an approval needs a commit of its own to tag.
  class NothingToMerge < StandardError; end

  # The remote is neither the empty repository a design repo starts from nor a
  # design repo Flosis started: it has branches but no master (GitHub's "Add a
  # README" creates main), or a master without the runtime (the app's own
  # repository, say).
  class NotEmpty < StandardError; end

  # Another holds the repo's lock, and the caller would rather not wait.
  class Busy < StandardError; end

  # A worktree and the clone no longer point at each other (see linked!):
  # its .git was changed, and git run there would act on whatever that file
  # names now. No git is run in it.
  class Tampered < StandardError; end

  # A git lock file this old was left by a git that was killed (a deploy stops
  # jobs mid-run). No git Flosis runs here takes that long, and a transfer that
  # stalls gives up after a minute (GitRunner.env).
  STALE_LOCK_AGE = 10.minutes

  class << self
    # Test seam: where the repo lives instead of GitHub (a bare repo on disk).
    attr_accessor :remote_url_override
  end

  attr_reader :project, :remote_url

  # Touches neither the disk nor the database, so a Repo can be built for a
  # project that has no folder yet (to rotate its preview token): the folders
  # resolve on first use.
  def initialize(project, remote_url: nil)
    @project = project
    @remote_url = remote_url || self.class.remote_url_override ||
                  GitRunner.github_url(ProjectCredentials.new(project).design_repo)
  end

  def root
    base_dir.join("design-repo")
  end

  def worktrees_root
    base_dir.join("design-worktrees")
  end

  # Holds an exclusive flock on design-repo.lock for the block. It is
  # re-entrant within a thread, whichever Repo of the project asks, and every
  # method below runs inside it. The lock file sits beside the clone, so
  # replacing the clone never touches it. With wait: false it raises Busy at
  # once if another holds the lock: a web request must not wait behind a job.
  #
  # The thread marks the lock held only inside the begin, so nothing that
  # fails or is interrupted on the way in leaves it marked held.
  def synchronize(wait: true)
    held = Thread.current.thread_variable_get(:designs_repo_locks) ||
           Thread.current.thread_variable_set(:designs_repo_locks, Set.new)
    return yield if held.include?(lock_path)

    FileUtils.mkdir_p(base_dir)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      raise Busy, "the design repo is busy" unless lock.flock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB)

      begin
        held << lock_path
        clear_stale_git_locks!
        yield
      ensure
        held.delete(lock_path)
      end
    end
  end

  # Leaves a clone of remote_url on master: at origin/master once the remote
  # has one, else on a master yet to be born. A remote with branches but no
  # master, or with a master that has no RUNTIME, is refused (NotEmpty), and
  # its clone is set aside like the one below, so that nothing of it is ever
  # committed on or pushed from.
  #
  # A clone of another repo (the project's design repo was changed) is moved
  # aside with its worktrees and never pushed from again, so the old history
  # cannot reach the new repo.
  def ensure_clone!
    synchronize do
      if clone_of_remote?
        # Set again on every run, not only at clone time: a commit made without
        # the identity would carry the host's own user into the client's
        # history, and a checkout with symlinks on would write links.
        CONFIG.each { |key, value| git("config", key, value) }
        git("fetch", "--prune", "--tags", "origin", token: token)
      else
        move_aside!
        clone!
      end

      if initialized?
        refuse_foreign_master!
        # Checks master out and resets it hard to origin/master in one step,
        # from an unborn HEAD too: commits and edits that never reached the
        # remote are dropped.
        git("checkout", "--force", "-B", MASTER, "origin/#{MASTER}")
      else
        refuse_occupied_remote!
        # An empty clone's HEAD names the remote's default branch (main, on
        # GitHub) or init.defaultBranch. The first commit belongs on master.
        git("symbolic-ref", "HEAD", "refs/heads/#{MASTER}") if unborn_head?
      end
      root
    end
  end

  # Whether master has reached the remote.
  def initialized?
    synchronize { ref?("refs/remotes/origin/#{MASTER}") }
  end

  # The folder a branch is checked out in, made on first use: from the local
  # branch, else from the remote's, else as a new branch off `from`.
  def worktree!(branch, from: MASTER)
    synchronize do
      dir = worktree_path(branch)
      next dir if dir.exist?

      # Forgets worktrees whose folders are gone: git refuses to add one again
      # while it is still registered.
      git("worktree", "prune")
      if ref?("refs/heads/#{branch}")
        git("worktree", "add", dir.to_s, branch)
      elsif ref?("refs/remotes/origin/#{branch}")
        git("worktree", "add", "-b", branch, dir.to_s, "origin/#{branch}")
      else
        git("worktree", "add", "-b", branch, dir.to_s, "refs/heads/#{from}")
      end
      dir
    end
  end

  # Stages everything in a checkout and reports, per staged path, the text it
  # adds: the leak guard reads it before anything is committed. Renames show
  # as a deletion and an addition, so every path touched is listed.
  def stage_all!(dir)
    synchronize do
      dir = own_checkout!(dir)
      git("add", "-A", chdir: dir)
      git("diff", "--cached", "--name-only", "--no-renames", "-z", chdir: dir).split("\0").map do |path|
        Change.new(path: path, added_text: added_text(dir, path))
      end
    end
  end

  # The new commit's sha, or nil when nothing is staged. The author is the
  # Flosis identity the clone was configured with.
  def commit!(dir, message:)
    synchronize do
      dir = own_checkout!(dir)
      next if git("diff", "--cached", "--name-only", chdir: dir).empty?

      git("commit", "--message", message, chdir: dir)
      git("rev-parse", "HEAD", chdir: dir).strip
    end
  end

  # Whether the checkout's index has a file at exactly this path: what the
  # next commit would hold, once stage_all! has run. ls-files also lists what
  # sits in a folder of that name, which does not count.
  def indexed?(dir, path)
    synchronize do
      dir = own_checkout!(dir)
      git("ls-files", "-z", "--", ":(literal)#{path}", chdir: dir).split("\0").include?(path)
    end
  end

  # Back to the checkout's last commit: edits undone and new files removed.
  # Files the repo ignores stay. The second -f removes a repository written
  # into the checkout too, which a single one skips: left there, it would fail
  # every later git add -A.
  def discard!(dir)
    synchronize do
      dir = own_checkout!(dir)
      git("reset", "--hard", chdir: dir)
      git("clean", "-ffd", chdir: dir)
    end
  end

  # Deletes a worktree's folder and git's record of it, so that worktree!
  # checks its branch out afresh: what is left to do with a worktree whose
  # link was changed (Tampered), where no git may run. The folder is checked
  # by its path alone, without asking git, and must sit directly in
  # worktrees_root. The branch keeps its commits; only what was never
  # committed goes with the folder.
  def remove_worktree!(dir)
    synchronize do
      path = Pathname(dir).expand_path
      raise ArgumentError, "#{path} is not a worktree folder of the design repo" unless path.dirname == worktrees_root

      FileUtils.rm_rf(path)
      git("worktree", "prune") if root.join(".git").exist?
    end
  end

  def push!(*refs)
    synchronize { git("push", "origin", *refs, token: token) }
  end

  # The local branch's sha, or nil when there is no such branch.
  def head(branch)
    synchronize { sha("refs/heads/#{branch}") }
  end

  # Where origin's branch was at the last fetch, or nil when it has none.
  def remote_head(branch)
    synchronize { sha("refs/remotes/origin/#{branch}") }
  end

  def commits_ahead(branch, base: MASTER)
    synchronize { git("rev-list", "--count", "refs/heads/#{base}..refs/heads/#{branch}").to_i }
  end

  def point!(branch, to:)
    synchronize { git("branch", "--force", branch, to) }
  end

  # Merges a branch into master as the clone has it, with a merge commit, and
  # returns master's new sha. Nothing is fetched or pushed here.
  def merge_into_master!(branch, message:)
    synchronize do
      before = head(MASTER)
      git("merge", "--no-ff", "--no-edit", "--message", message, "refs/heads/#{branch}")
      # A branch master already contains is "Already up to date.": git exits 0
      # without a commit, and master comes back as it was.
      merged = head(MASTER)
      raise NothingToMerge, "#{MASTER} already contains everything on #{branch}" if merged == before

      merged
    rescue GitRunner::Error
      # git reports a conflict on stdout, which GitRunner::Error does not
      # carry. MERGE_HEAD is the sign: it exists only while a merge waits for
      # its conflicts to be resolved. Any other failure stays git's own error.
      raise unless root.join(".git", "MERGE_HEAD").exist?

      paths = git("diff", "--name-only", "--diff-filter=U").split("\n")
      git("merge", "--abort")
      raise Conflict, "#{branch} does not merge cleanly into #{MASTER}: #{paths.join(", ")}"
    end
  end

  def tag!(name, at:)
    synchronize { git("tag", name, at) }
  end

  def tags(pattern)
    synchronize { git("tag", "-l", pattern, "--sort=v:refname").split("\n") }
  end

  # Renames a branch here, in its worktree folder's name and on the remote: a
  # task's branches take its Jira key once the issue exists.
  def rename!(from, to)
    synchronize do
      pushed = ref?("refs/remotes/origin/#{from}")
      git("branch", "-m", from, to)
      git("worktree", "move", worktree_path(from).to_s, worktree_path(to).to_s) if worktree_path(from).exist?
      push!(to)
      # A branch that no turn ever pushed has nothing on the remote to delete.
      push!("--delete", from) if pushed
    end
  end

  private

  def base_dir
    @base_dir ||= Pathname(project.designs_dir).expand_path
  end

  def lock_path
    base_dir.join("design-repo.lock").to_s
  end

  # Every git Flosis runs in this repo runs under the lock, so once it is taken
  # a git lock file (index.lock, a ref's .lock, a worktree's) is one a killed
  # git left behind, and every later git would fail on it. Old ones only: a
  # git orphaned by a killed job can still be running for a while. objects/,
  # by far the largest folder, is left out: none of the commands run here
  # takes a lock file in it.
  def clear_stale_git_locks!
    git_dir = root.join(".git")
    return unless git_dir.directory?

    Dir.glob(%w[*.lock {refs,logs,worktrees}/**/*.lock], base: git_dir.to_s).each do |name|
      lock = git_dir.join(name)
      lock.delete if lock.file? && lock.mtime < STALE_LOCK_AGE.ago
    rescue Errno::ENOENT
      nil # gone in the meantime
    end
  end

  def worktree_path(branch)
    worktrees_root.join(branch.gsub("/", "__"))
  end

  def token
    ProjectCredentials.new(project).design_repo_token
  end

  def git(*args, chdir: root, token: nil)
    GitRunner.run!(*args, chdir: chdir, token: token)
  end

  def clone_of_remote?
    root.join(".git").exist? && origin_url == remote_url
  end

  # The URL as configured: `git remote get-url` would apply url.*.insteadOf
  # rewrites and see a different repo every time.
  def origin_url
    git("config", "--get", "remote.origin.url").strip
  rescue GitRunner::Error
    nil # no origin, or no readable repo at all: not a clone of remote_url either way
  end

  # The clone and its worktrees share one tag, so they can be matched up
  # afterwards. The random part is there because a refused repo is refused
  # again by the next job, which can come within the same second: renaming onto
  # the first clone's name would fail with a filesystem error instead of NotEmpty.
  def move_aside!
    tag = "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(3)}"
    [ root, worktrees_root ].each { |dir| File.rename(dir, "#{dir}.replaced-#{tag}") if dir.exist? }
  end

  # CONFIG goes into the clone's own config, which its worktrees share. git
  # writes it as it creates the repo, before the remote is even configured and
  # before anything is checked out, so the first checkout writes no symlink and
  # a clone cut short that ensure_clone! would keep already has it.
  def clone!
    config = CONFIG.flat_map { |key, value| [ "--config", "#{key}=#{value}" ] }
    git("clone", *config, "--", remote_url, root.to_s, chdir: base_dir, token: token)
  end

  def refuse_occupied_remote!
    branches = git("for-each-ref", "--format=%(refname)", "refs/remotes/origin").lines(chomp: true)
                 .map { |ref| ref.delete_prefix("refs/remotes/origin/") } - [ "HEAD" ]
    return if branches.empty?

    # A clone of this very remote is one ensure_clone! keeps, so a refused one
    # left in place would be fetched into and committed on by the next run,
    # on top of the old main, once the repo had been emptied. It is set aside
    # like a clone of another repo.
    move_aside!
    named = branches.first(BRANCHES_NAMED).join(", ")
    named += " and #{branches.size - BRANCHES_NAMED} more" if branches.size > BRANCHES_NAMED
    raise NotEmpty, "The design repo must be empty — it already has: #{named}. #{REMEDY}"
  end

  # Only a master Flosis started is taken on. Any other (the app's own
  # repository, say) would have its files published as designs, and every
  # task's branch pushed and every approval merged into it. RUNTIME must be a
  # file: ls-tree names what is at the path, a folder as a tree. The clone is
  # set aside, as for any refusal: emptied and started afresh, the repo must
  # not get the old master's history back from it.
  def refuse_foreign_master!
    return if git("ls-tree", "origin/#{MASTER}", "--", RUNTIME).split(" ", 3)[1] == "blob"

    move_aside!
    raise NotEmpty, "The design repo already has a #{MASTER} that Flosis did not start (it has no #{RUNTIME}). #{REMEDY}"
  end

  # HEAD names a branch with no commit yet: the state of a fresh clone of an
  # empty repo.
  def unborn_head?
    !ref?(git("symbolic-ref", "HEAD").strip)
  end

  # Git runs only in this repo's own checkouts. discard! resets and cleans:
  # pointed at the app's checkout by mistake, it would wipe it. A worktree's
  # link is checked on every call too (see linked!): Claude edits the files in
  # a worktree, and git trusts whatever its .git says.
  def own_checkout!(dir)
    path = Pathname(dir).expand_path
    return path if path == root
    raise ArgumentError, "#{path} is not a checkout of the design repo" unless path.dirname == worktrees_root

    linked!(path)
    path
  end

  # A worktree and the clone point at each other: the worktree's .git is a
  # plain file reading "gitdir: <root>/.git/worktrees/<name>", and the gitdir
  # file in that folder names the worktree's .git back. A .git naming any
  # other git folder (another repository's, the clone's own, another
  # worktree's) would have discard! reset and clean there instead. Paths are
  # compared resolved: git writes them so (macOS's /var is /private/var), and
  # with worktree.useRelativePaths relative to the file that holds them.
  def linked!(path)
    dot_git = path.join(".git")
    raise Tampered, tampered(path) unless dot_git.lstat.file?

    target = dot_git.read.scrub[/\Agitdir: (.+)\n?\z/, 1]
    raise Tampered, tampered(path) unless target

    admin = Pathname(File.realpath(path.join(target)))
    back = admin.join("gitdir").read.scrub.chomp
    linked = admin.dirname == Pathname(File.realpath(root.join(".git", "worktrees"))) &&
             File.realpath(admin.join(back)) == File.realpath(dot_git)
    raise Tampered, tampered(path) unless linked
  rescue SystemCallError, ArgumentError
    # A link to nothing (a missing .git, folder or gitdir file), or to no path
    # at all (one with a NUL byte in it), is no link.
    raise Tampered, tampered(path)
  end

  def tampered(path)
    "the design worktree #{path.basename} no longer links to the design repo, so no git was run in it"
  end

  # The "+" lines of the path's staged diff, without the "+". Only lines in a
  # hunk count: an added line that itself starts with "++" reads "+++" in the
  # diff, like the file header. --text keeps a .gitattributes from turning the
  # file into "Binary files differ", and :(literal) keeps the path from being
  # read as a pattern.
  def added_text(dir, path)
    diff = git("diff", "--cached", "--no-renames", "-U0", "--text", "--no-color", "--no-ext-diff", "--no-textconv",
               "--", ":(literal)#{path}", chdir: dir).scrub
    diff.lines.drop_while { |line| !line.start_with?("@@") }
        .filter_map { |line| line.delete_prefix("+") if line.start_with?("+") }.join
  end

  # for-each-ref also lists what sits under a name ("refs/heads/wip" lists
  # every wip/ branch), so only the exact ref counts.
  def sha(ref)
    refs = git("for-each-ref", "--format=%(objectname) %(refname)", ref).lines.map(&:split)
    refs.find { |_, name| name == ref }&.first
  end

  def ref?(ref)
    !sha(ref).nil?
  end
end
