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

  Change = Data.define(:path, :added_text)

  # The merge stopped on conflicting files. It has been aborted, so master is
  # where it was.
  class Conflict < StandardError; end

  # master already has everything on the branch. A merge would make no commit,
  # and an approval needs a commit of its own to tag.
  class NothingToMerge < StandardError; end

  # The remote has branches but no master, so it is not the empty repository a
  # design repo starts from (GitHub's "Add a README" creates main).
  class NotEmpty < StandardError; end

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
  # replacing the clone never touches it.
  def synchronize
    held = Thread.current.thread_variable_get(:designs_repo_locks) ||
           Thread.current.thread_variable_set(:designs_repo_locks, Set.new)
    return yield if held.include?(lock_path)

    FileUtils.mkdir_p(base_dir)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      held << lock_path
      begin
        yield
      ensure
        held.delete(lock_path)
      end
    end
  end

  # Leaves a clone of remote_url on master: at origin/master once the remote
  # has one, else on a master yet to be born. A remote with branches but no
  # master is refused (NotEmpty), and its clone is set aside like the one
  # below, so that emptying the remote, as the error advises, starts afresh.
  #
  # A clone of another repo (the project's design repo was changed) is moved
  # aside with its worktrees and never pushed from again, so the old history
  # cannot reach the new repo.
  def ensure_clone!
    synchronize do
      if clone_of_remote?
        # Set again on every run, not only at clone time: a commit made without
        # it would carry the host's own user into the client's history.
        IDENTITY.each { |key, value| git("config", key, value) }
        git("fetch", "--prune", "--tags", "origin", token: token)
      else
        move_aside!
        clone!
      end

      if initialized?
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

  # Back to the checkout's last commit: edits undone and new files removed.
  # Files the repo ignores stay.
  def discard!(dir)
    synchronize do
      dir = own_checkout!(dir)
      git("reset", "--hard", chdir: dir)
      git("clean", "-fd", chdir: dir)
    end
  end

  def push!(*refs)
    synchronize { git("push", "origin", *refs, token: token) }
  end

  # The local branch's sha, or nil when there is no such branch.
  def head(branch)
    synchronize { sha("refs/heads/#{branch}") }
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

  # The Flosis identity goes into the clone's own config, which its worktrees
  # share, so every commit and merge made here is Flosis's. git writes it as it
  # creates the repo, before the remote is even configured, so a clone cut
  # short that ensure_clone! would keep already has it.
  def clone!
    identity = IDENTITY.flat_map { |key, value| [ "--config", "#{key}=#{value}" ] }
    git("clone", *identity, "--", remote_url, root.to_s, chdir: base_dir, token: token)
  end

  def refuse_occupied_remote!
    branches = git("for-each-ref", "--format=%(refname)", "refs/remotes/origin").lines(chomp: true)
                 .map { |ref| ref.delete_prefix("refs/remotes/origin/") } - [ "HEAD" ]
    return if branches.empty?

    # A clone of this very remote is one ensure_clone! keeps, so a refused one
    # left in place would be fetched into and committed on by the next run,
    # on top of the old main, once the repo had been emptied as the message
    # advises. It is set aside like a clone of another repo.
    move_aside!
    raise NotEmpty, "The design repo must be empty — it already has: #{branches.join(", ")}. " \
                    "Create an empty repository, or remove them."
  end

  # HEAD names a branch with no commit yet: the state of a fresh clone of an
  # empty repo.
  def unborn_head?
    !ref?(git("symbolic-ref", "HEAD").strip)
  end

  # Git runs only in this repo's own checkouts. discard! resets and cleans:
  # pointed at the app's checkout by mistake, it would wipe it.
  def own_checkout!(dir)
    path = Pathname(dir).expand_path
    return path if path == root || path.dirname == worktrees_root

    raise ArgumentError, "#{path} is not a checkout of the design repo"
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
