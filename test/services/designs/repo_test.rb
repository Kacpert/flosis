require "test_helper"

class Designs::RepoTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  test "ensure_clone! clones an empty remote, which is not initialized yet" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      assert repo.root.join(".git").exist?
      assert_not repo.initialized?
    end
  end

  test "the first commit on master reaches the remote and initializes the repo" do
    with_design_remote do |repo, remote|
      sha = seed_master(repo)
      assert_equal sha, remote_branch_sha(remote, "master")
      assert repo.initialized?
    end
  end

  test "no token ends up in the clone's config" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      assert_not_includes repo.root.join(".git/config").read, "design-token"
    end
  end

  test "a working branch starts from master and its commits reach the remote" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      sha = commit_files(repo, dir, { "designs/jobs.html" => "<p>jobs</p>" })
      repo.push!("wip/REC-1")
      assert_equal sha, remote_branch_sha(remote, "wip/REC-1")
      assert_equal 1, repo.commits_ahead("wip/REC-1")
    end
  end

  test "commit! returns nil when nothing changed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      repo.stage_all!(dir)
      assert_nil repo.commit!(dir, message: "nothing")
    end
  end

  test "stage_all! reports each path with the text it adds" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("README.md"), "hi\nnew line\n")
      changes = repo.stage_all!(dir)
      assert_equal [ "README.md" ], changes.map(&:path)
      assert_includes changes.first.added_text, "new line"
    end
  end

  test "discard! throws away uncommitted work" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("stray.html"), "x")
      repo.discard!(dir)
      assert_not dir.join("stray.html").exist?
    end
  end

  test "approving points the design branch at the work and merges it into master with a merge commit" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      wip = commit_files(repo, dir, { "designs/jobs.html" => "<p>jobs</p>" })
      repo.point!("design/REC-1", to: wip)
      merged = repo.merge_into_master!("design/REC-1", message: "Approve REC-1")
      repo.push!("design/REC-1", "master")
      assert_equal wip, remote_branch_sha(remote, "design/REC-1")
      assert_equal merged, remote_branch_sha(remote, "master")
      parents = GitRunner.run!("rev-list", "--parents", "-n", "1", merged, chdir: repo.root).split
      assert_equal 3, parents.size, "a merge commit has two parents"
    end
  end

  test "a conflicting merge raises Conflict and leaves master as it was" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/a.html" => "base\n" })
      dir = repo.worktree!("wip/REC-1")
      wip = commit_files(repo, dir, { "designs/a.html" => "from the task\n" })
      before = commit_files(repo, repo.root, { "designs/a.html" => "from master\n" })
      repo.point!("design/REC-1", to: wip)
      assert_raises(Designs::Repo::Conflict) { repo.merge_into_master!("design/REC-1", message: "Approve REC-1") }
      assert_equal before, repo.head("master")
      assert_empty GitRunner.run!("status", "--porcelain", chdir: repo.root)
    end
  end

  test "approval tags list in numeric order" do
    with_design_remote do |repo, _|
      sha = seed_master(repo)
      %w[1 2 10].each { |n| repo.tag!("approved/REC-1/#{n}", at: sha) }
      assert_equal %w[approved/REC-1/1 approved/REC-1/2 approved/REC-1/10], repo.tags("approved/REC-1/*")
    end
  end

  test "rename! moves a branch to its Jira name on the remote" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/task-5")
      sha = commit_files(repo, dir, { "designs/x.html" => "x" })
      repo.push!("wip/task-5")
      repo.rename!("wip/task-5", "wip/REC-9")
      assert_equal sha, remote_branch_sha(remote, "wip/REC-9")
      assert_nil remote_branch_sha(remote, "wip/task-5")
    end
  end

  test "ensure_clone! re-clones when the repo changes" do
    other_dir = Dir.mktmpdir("other-remote")
    with_design_remote do |repo, _|
      seed_master(repo)
      other = File.join(other_dir, "other.git")
      system("git", "init", "--bare", "--quiet", other, exception: true)
      moved = Designs::Repo.new(repo.project, remote_url: other)
      moved.ensure_clone!
      assert_not moved.initialized?, "the new repo starts empty, not with the old history"
    end
  ensure
    FileUtils.remove_entry(other_dir)
  end

  test "synchronize serializes concurrent callers" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      repos = 2.times.map { Designs::Repo.new(repo.project, remote_url: repo.remote_url) }
      log = Queue.new
      repos.each_with_index.map { |r, i|
        Thread.new { r.synchronize { log << [ :in, i ]; sleep 0.2; log << [ :out, i ] } }
      }.each(&:join)
      assert_equal %i[in out in out], 4.times.map { log.pop.first }
    end
  end

  # A repo just created on GitHub has no branches, and its HEAD names GitHub's
  # default branch, main: a clone of it would make its first commit on main.
  test "an empty repo is cloned onto master, whatever branch the remote names" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      repo.ensure_clone!
      assert_equal "refs/heads/master", GitRunner.run!("symbolic-ref", "HEAD", chdir: repo.root).strip
      assert_equal seed_master(repo), remote_branch_sha(remote, "master")
    end
  end

  test "ensure_clone! keeps a clone of the same repo and puts master back where the remote has it" do
    with_design_remote do |repo, _|
      pushed = seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, repo.root, { "designs/local.html" => "never pushed" })
      repo.ensure_clone!
      assert_equal pushed, repo.head("master")
      assert_not repo.root.join("designs/local.html").exist?
      assert dir.exist?, "the worktrees stay"
      assert_empty Dir.glob("#{repo.root}.replaced-*")
    end
  end

  test "a replaced clone and its worktrees are moved aside, not deleted" do
    other_dir = Dir.mktmpdir("other-remote")
    with_design_remote do |repo, _|
      seed_master(repo)
      repo.worktree!("wip/REC-1")
      other = File.join(other_dir, "other.git")
      system("git", "init", "--bare", "--quiet", other, exception: true)
      Designs::Repo.new(repo.project, remote_url: other).ensure_clone!
      assert_equal 1, Dir.glob("#{repo.root}.replaced-*/.git").size
      assert_equal 1, Dir.glob("#{repo.worktrees_root}.replaced-*/wip__REC-1").size
      assert_not repo.worktrees_root.exist?
    end
  ensure
    FileUtils.remove_entry(other_dir)
  end

  # The leak guard reads added_text: whatever the diff hides from it is
  # committed unchecked.
  test "an added line that starts with ++ is added text, not a diff header" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("README.md"), "hi\n++ghp_SECRET123\n")
      assert_equal "++ghp_SECRET123\n", repo.stage_all!(dir).first.added_text
    end
  end

  test "a .gitattributes cannot hide a file's text from stage_all!" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      FileUtils.mkdir_p(dir.join("designs"))
      File.write(dir.join("designs/.gitattributes"), "* binary\n")
      File.write(dir.join("designs/a.html"), "token=ghp_SECRET123\n")
      added = repo.stage_all!(dir).to_h { |change| [ change.path, change.added_text ] }
      assert_equal "token=ghp_SECRET123\n", added["designs/a.html"]
    end
  end

  test "rename! moves the worktree too, and a branch that never reached the remote is only pushed" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      old_dir = repo.worktree!("wip/task-5")
      repo.rename!("wip/task-5", "wip/REC-9")
      assert_not old_dir.exist?
      assert_nil repo.head("wip/task-5")
      assert_equal repo.head("wip/REC-9"), remote_branch_sha(remote, "wip/REC-9")
      sha = commit_files(repo, repo.worktree!("wip/REC-9"), { "designs/x.html" => "x" })
      assert_equal sha, repo.head("wip/REC-9")
    end
  end

  test "a worktree whose folder was deleted is checked out again" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      FileUtils.rm_rf(dir)
      assert_equal dir, repo.worktree!("wip/REC-1")
      assert dir.join("README.md").exist?
    end
  end

  # A deploy stops jobs mid-run. A git killed there left its lock file, and
  # every later git in the repo failed on it ("index.lock: File exists").
  test "taking the lock clears the lock files a killed git left, and keeps a fresh one" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      git_dir = repo.root.join(".git")
      stale = %w[index.lock refs/heads/master.lock worktrees/wip__REC-1/index.lock].map { |name| git_dir.join(name) }
      fresh = git_dir.join("fresh.lock")
      long_ago = Time.now - 11 * 60
      (stale + [ fresh ]).each { |lock| File.write(lock, "") }
      stale.each { |lock| File.utime(long_ago, long_ago, lock) }

      commit_files(repo, dir, { "designs/a.html" => "a" })
      commit_files(repo, repo.root, { "designs/b.html" => "b" })

      stale.each { |lock| assert_not lock.exist?, lock.to_s }
      assert fresh.exist?, "a lock file younger than ten minutes can be a git that is still running"
    end
  end

  # The Designs tab rotates preview links from a web request, which must not
  # wait behind a job that holds the repo (a set-up can take minutes).
  test "synchronize without waiting raises Busy at once while another holds the lock" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      ran = false
      File.open(repo.root.dirname.join("design-repo.lock")) do |job|
        job.flock(File::LOCK_EX)
        assert_raises(Designs::Repo::Busy) { repo.synchronize(wait: false) { ran = true } }
      end
      assert_not ran
      assert_equal :free, repo.synchronize(wait: false) { :free }
      assert_equal :nested, repo.synchronize { repo.synchronize(wait: false) { :nested } }, "re-entrant within the thread that holds it"
    end
  end

  # Marked held, a lock this thread no longer holds would let every later
  # synchronize in the thread run without it.
  test "a failure as the lock is taken leaves it neither held nor marked held" do
    with_design_remote do |repo, _|
      repo.ensure_clone!
      broken = Designs::Repo.new(repo.project, remote_url: repo.remote_url)
      broken.define_singleton_method(:clear_stale_git_locks!) { raise "boom" }
      assert_raises(RuntimeError) { broken.synchronize { flunk "ran after a failure" } }

      lock_path = repo.root.dirname.join("design-repo.lock")
      taken_elsewhere = repo.synchronize { File.open(lock_path) { |other| other.flock(File::LOCK_EX | File::LOCK_NB) } }
      assert_equal false, taken_elsewhere, "the next synchronize in this thread ran without the lock"
    end
  end

  test "synchronize is re-entrant within a thread, across Repo objects of one project" do
    with_design_remote do |repo, _|
      other = Designs::Repo.new(repo.project, remote_url: repo.remote_url)
      assert_equal :inside, Timeout.timeout(5) { repo.synchronize { other.synchronize { :inside } } }
    end
  end

  test "commits and merges are Flosis's, in worktrees too" do
    with_design_remote do |repo, _|
      seed = seed_master(repo)
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      repo.point!("design/REC-1", to: wip)
      merged = repo.merge_into_master!("design/REC-1", message: "Approve REC-1")
      [ seed, wip, merged ].each do |sha|
        assert_equal "Flosis <designs@flosis.com> / Flosis <designs@flosis.com>",
                     GitRunner.run!("log", "-1", "--format=%an <%ae> / %cn <%ce>", sha, chdir: repo.root).strip
      end
    end
  end

  # A clone cut short, or one that lost the keys, would otherwise commit as the
  # host's own user, and that identity would be pushed into the client's history.
  test "a clone without the Flosis identity gets it back" do
    with_design_remote do |repo, _|
      seed_master(repo)
      GitRunner.run!("config", "--unset", "user.name", chdir: repo.root)
      GitRunner.run!("config", "--unset", "user.email", chdir: repo.root)
      repo.ensure_clone!
      sha = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      assert_equal "Flosis <designs@flosis.com> / Flosis <designs@flosis.com>",
                   GitRunner.run!("log", "-1", "--format=%an <%ae> / %cn <%ce>", sha, chdir: repo.root).strip
    end
  end

  # A client can push a design as a symlink, to the app's .env.production say.
  # Checked out as a link, Claude's tools would follow it out of the checkout.
  test "a symlink pushed to the repo is checked out as a plain file holding its target" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      Dir.mktmpdir("elsewhere") do |dir|
        system("git", "clone", "--quiet", remote, dir, exception: true, err: File::NULL)
        FileUtils.mkdir_p(File.join(dir, "designs"))
        File.symlink("../../.env.production", File.join(dir, "designs/x.html"))
        system("git", "-C", dir, "add", "-A", exception: true)
        system("git", "-C", dir, "-c", "user.name=Someone", "-c", "user.email=someone@example.com",
               "commit", "--quiet", "-m", "a link", exception: true)
        system("git", "-C", dir, "push", "--quiet", "origin", "HEAD:refs/heads/wip/REC-1", "HEAD:refs/heads/master",
               exception: true, err: File::NULL)
      end

      repo.ensure_clone!
      [ repo.worktree!("wip/REC-1"), repo.root ].each do |checkout|
        file = checkout.join("designs/x.html")
        assert_not file.symlink?, "#{checkout} has it as a link"
        assert_equal "../../.env.production", file.read, checkout.to_s
      end
    end
  end

  test "a clone that lost core.symlinks=false gets it back" do
    with_design_remote do |repo, _|
      seed_master(repo)
      GitRunner.run!("config", "core.symlinks", "true", chdir: repo.root)
      repo.ensure_clone!
      assert_equal "false", GitRunner.run!("config", "core.symlinks", chdir: repo.root).strip
    end
  end

  # GitHub's "Add a README" (or a license, or a .gitignore) creates main. Put
  # on master, a clone of it would stage those files into the first commit.
  test "a repo that already has branches, but no master, is refused" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n", "LICENSE" => "MIT\n" })
      error = assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
      assert_equal "The design repo must be empty — it already has: main. " \
                   "Create a new, empty repository (no README, licence or .gitignore).", error.message
      assert_nil remote_branch_sha(remote, "master")
    end
  end

  # Re-pointing a HEAD that has commits would leave its files staged for
  # master's first commit: only an empty clone's HEAD is moved. The refused
  # clone is not kept (see the next test), so the emptied repo is cloned afresh
  # and its HEAD is the unborn one that may be moved.
  test "a repo emptied after it was refused is cloned afresh, unborn on master, with nothing of the old main" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n" })
      assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
      system("git", "-C", remote, "update-ref", "-d", "refs/heads/main", exception: true)
      repo.ensure_clone!
      assert_equal "refs/heads/master", GitRunner.run!("symbolic-ref", "HEAD", chdir: repo.root).strip
      assert_empty GitRunner.run!("for-each-ref", "refs/heads", chdir: repo.root), "no main, no branch at all"
      assert_empty GitRunner.run!("diff", "--cached", "--name-only", chdir: repo.root)
      assert_equal [ ".git" ], Dir.children(repo.root), "none of main's files"
      assert_not repo.initialized?

      first = seed_master(repo)
      assert_equal [ first ], GitRunner.run!("rev-list", "--parents", "-n", "1", first, chdir: repo.root).split,
                   "master's first commit is a root commit, not one on top of main's history"
    end
  end

  # A clone of the same remote is the one ensure_clone! keeps, fetches into and
  # commits on. A refused one left in place would turn emptying the repo, as the
  # error advises, into committing onto the old main.
  test "a refused clone is moved aside, not kept and not deleted" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n" })
      error = assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
      assert_equal "The design repo must be empty — it already has: main. " \
                   "Create a new, empty repository (no README, licence or .gitignore).", error.message
      assert_not repo.root.exist?
      assert_equal 1, Dir.glob("#{repo.root}.replaced-*/.git").size
    end
  end

  # An initialized repo whose master was swapped for another branch is refused
  # the same way, with its local master and its worktrees.
  test "a refused clone is set aside with its worktrees" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      repo.worktree!("wip/REC-1")
      system("git", "-C", remote, "update-ref", "refs/heads/main", remote_branch_sha(remote, "master"), exception: true)
      system("git", "-C", remote, "update-ref", "-d", "refs/heads/master", exception: true)
      assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
      assert_not repo.root.exist?
      assert_not repo.worktrees_root.exist?
      assert_equal 1, Dir.glob("#{repo.root}.replaced-*/.git").size
      assert_equal 1, Dir.glob("#{repo.worktrees_root}.replaced-*/wip__REC-1").size
    end
  end

  # Two jobs queued by a double click refuse the repo one after the other, and
  # can do it within a second: the first clone's name must not be taken.
  test "clones refused within the same second are each set aside" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n" })
      freeze_time do
        2.times { assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! } }
      end
      assert_equal 2, Dir.glob("#{repo.root}.replaced-*/.git").size
    end
  end

  # Any remote with a master used to be taken on as it was, the app's own
  # repository included: its files published, and every task's branch pushed
  # into it.
  test "a remote whose master Flosis did not start is refused, and its clone set aside" do
    with_design_remote do |repo, remote|
      push_from_elsewhere(remote, "master", { "Gemfile" => "gem \"rails\"\n", "secrets.json" => "{}\n",
                                              "README.md" => "# acme app\n" })
      before = remote_branch_sha(remote, "master")
      error = assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
      assert_equal "The design repo already has a master that Flosis did not start (it has no runtime/flosis.js). " \
                   "Create a new, empty repository (no README, licence or .gitignore).", error.message
      assert_not repo.root.exist?
      assert_equal 1, Dir.glob("#{repo.root}.replaced-*/.git").size
      assert_equal before, remote_branch_sha(remote, "master")
    end
  end

  test "a master that holds the runtime is taken on, wherever it was started" do
    with_design_remote do |repo, remote|
      push_from_elsewhere(remote, "master", { "runtime/flosis.js" => "// runtime\n", "README.md" => "# designs\n" })
      repo.ensure_clone!
      assert repo.initialized?
      assert_equal remote_branch_sha(remote, "master"), repo.head("master")
    end
  end

  # A folder named like the runtime is not the runtime.
  test "a master whose runtime/flosis.js is not a file is refused" do
    with_design_remote do |repo, remote|
      push_from_elsewhere(remote, "master", { "runtime/flosis.js/index.html" => "<p>x</p>\n" })
      assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
    end
  end

  # The refusal is shown on the Designs tab and stored cut to 500 characters:
  # however many branches the repo has, the remedy must still be there.
  test "a refused repo's error names ten of its branches at most, then the remedy" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n" })
      main = remote_branch_sha(remote, "main")
      refs = (1..80).map { |n| "create refs/heads/branch-number-#{n} #{main}\n" }.join
      _, status = Open3.capture2e("git", "-C", remote, "update-ref", "--stdin", stdin_data: refs)
      assert status.success?

      error = assert_raises(Designs::Repo::NotEmpty) { repo.ensure_clone! }
      assert_equal "The design repo must be empty — it already has: branch-number-1, branch-number-10, " \
                   "branch-number-11, branch-number-12, branch-number-13, branch-number-14, branch-number-15, " \
                   "branch-number-16, branch-number-17, branch-number-18 and 71 more. " \
                   "Create a new, empty repository (no README, licence or .gitignore).", error.message
    end
  end

  # Approving with no new work: merge --no-ff says "Already up to date." and
  # succeeds without a commit, and the approval would tag an older one.
  test "merging a branch master already contains raises NothingToMerge and leaves master as it was" do
    with_design_remote do |repo, _|
      seed_master(repo)
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      repo.point!("design/REC-1", to: wip)
      merged = repo.merge_into_master!("design/REC-1", message: "Approve REC-1")
      assert_raises(Designs::Repo::NothingToMerge) { repo.merge_into_master!("design/REC-1", message: "Approve REC-1 again") }
      assert_equal merged, repo.head("master")
      assert_empty GitRunner.run!("status", "--porcelain", chdir: repo.root)
    end
  end

  test "a merge that fails for another reason raises git's error, not Conflict" do
    with_design_remote do |repo, _|
      seed_master(repo)
      error = assert_raises(GitRunner::Error) { repo.merge_into_master!("design/NOPE", message: "Approve") }
      assert_match(/not something we can merge/, error.message)
    end
  end

  # discard! resets and cleans: pointed at the app's checkout by mistake, it
  # would wipe it.
  test "git runs only in the repo's own checkouts" do
    with_design_remote do |repo, _|
      seed_master(repo)
      app = repo.root.dirname.join("app")
      system("git", "init", "--quiet", app.to_s, exception: true)
      File.write(app.join("work.rb"), "keep me")
      assert_raises(ArgumentError) { repo.discard!(app) }
      assert_raises(ArgumentError) { repo.stage_all!(app) }
      assert_raises(ArgumentError) { repo.commit!(app, message: "x") }
      assert app.join("work.rb").exist?
    end
  end

  # Ruling P2-R23. Claude edits the files in a worktree, its .git among them,
  # and git trusts whatever that file names: pointed at another repository's
  # git folder, discard! would reset that one and stage_all! stage into it.
  test "git refuses a worktree whose .git names another repository, and runs nothing there" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      other = repo.root.dirname.join("other")
      system("git", "init", "--quiet", other.to_s, exception: true)
      File.write(other.join("work.rb"), "v1\n")
      system("git", "-C", other.to_s, "add", "work.rb", exception: true)
      system("git", "-C", other.to_s, "-c", "user.name=Dev", "-c", "user.email=dev@example.com",
             "commit", "--quiet", "-m", "work", exception: true)
      File.write(other.join("work.rb"), "v2, staged\n")
      system("git", "-C", other.to_s, "add", "work.rb", exception: true)
      File.write(dir.join("designs.html"), "<p>x</p>")
      dir.join(".git").write("gitdir: #{other.join(".git")}\n")

      assert_raises(Designs::Repo::Tampered) { repo.stage_all!(dir) }
      assert_raises(Designs::Repo::Tampered) { repo.commit!(dir, message: "x") }
      assert_raises(Designs::Repo::Tampered) { repo.discard!(dir) }
      assert_equal "M  work.rb\n", GitRunner.run!("status", "--porcelain", chdir: other), "its index is as it was"
      assert_equal "v2, staged\n", other.join("work.rb").read
    end
  end

  # Pointed at the clone's own git folder, a reset in the worktree would move
  # master.
  test "git refuses a worktree whose .git names the clone itself" do
    with_design_remote do |repo, _|
      master = seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/a.html" => "a" })
      dir.join(".git").write("gitdir: #{File.realpath(repo.root.join(".git"))}\n")

      assert_raises(Designs::Repo::Tampered) { repo.discard!(dir) }
      assert_raises(Designs::Repo::Tampered) { repo.stage_all!(dir) }
      assert_equal master, repo.head("master")
      assert_empty GitRunner.run!("status", "--porcelain", chdir: repo.root)
    end
  end

  # The link holds both ways: a .git naming another worktree's git folder
  # reads like a link to this clone, but that folder names the other worktree
  # back, and a reset here would use the other branch's index and HEAD.
  test "git refuses a worktree whose .git names another worktree's git folder" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      other = repo.worktree!("wip/REC-2")
      other_sha = commit_files(repo, other, { "designs/b.html" => "b" })
      dir.join(".git").write("gitdir: #{File.realpath(repo.root.join(".git/worktrees/wip__REC-2"))}\n")

      assert_raises(Designs::Repo::Tampered) { repo.discard!(dir) }
      assert_equal other_sha, repo.head("wip/REC-2")
      assert other.join("designs/b.html").exist?
    end
  end

  # Claude can write a git folder of its own inside the worktree, gitdir file
  # and all; only the clone's worktrees folder holds real ones.
  test "git refuses a worktree whose .git names a git folder outside the clone's, even one that names it back" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      fake = dir.join("designs/fake")
      FileUtils.mkdir_p(fake)
      FileUtils.cp_r("#{repo.root.join(".git/worktrees/wip__REC-1")}/.", fake)
      assert_equal "#{File.realpath(dir)}/.git\n", fake.join("gitdir").read
      dir.join(".git").write("gitdir: #{fake}\n")

      assert_raises(Designs::Repo::Tampered) { repo.discard!(dir) }
      assert fake.join("gitdir").exist?
    end
  end

  test "git refuses a worktree whose git folder no longer names it back" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      other = repo.worktree!("wip/REC-2")
      repo.root.join(".git/worktrees/wip__REC-1/gitdir").write("#{File.realpath(other)}/.git\n")

      assert_raises(Designs::Repo::Tampered) { repo.discard!(dir) }
    end
  end

  test "git refuses a worktree whose .git is not a plain file, or is gone" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      admin = dir.join(".git").read[/\Agitdir: (.+)$/, 1]

      dir.join(".git").delete
      File.symlink(admin, dir.join(".git"))
      assert_raises(Designs::Repo::Tampered, "a link to the git folder") { repo.discard!(dir) }

      dir.join(".git").delete
      dir.join(".git").mkdir
      assert_raises(Designs::Repo::Tampered, "a repository of its own") { repo.discard!(dir) }

      dir.join(".git").rmdir
      assert_raises(Designs::Repo::Tampered, "no link at all") { repo.discard!(dir) }

      dir.join(".git").write("gitdir: #{admin}\nworktree: /elsewhere\n")
      assert_raises(Designs::Repo::Tampered, "more than the link") { repo.discard!(dir) }

      dir.join(".git").write("gitdir: #{admin}\0\n")
      assert_raises(Designs::Repo::Tampered, "no path at all") { repo.discard!(dir) }
    end
  end

  # git writes the links resolved (on macOS, /var is /private/var) and, with
  # worktree.useRelativePaths, relative to the files that hold them.
  test "a worktree linked by relative paths is still the clone's own" do
    with_design_remote do |repo, _|
      seed_master(repo)
      GitRunner.run!("config", "worktree.useRelativePaths", "true", chdir: repo.root)
      dir = repo.worktree!("wip/REC-1")
      skip "this git writes absolute links only" unless dir.join(".git").read.start_with?("gitdir: ../")

      assert commit_files(repo, dir, { "designs/a.html" => "a" })
      repo.discard!(dir)
    end
  end

  # Ruling P2-R30. Claude can write a repository of its own into a worktree,
  # file by file. git clean -fd skips one, and every later git add -A fails on
  # it, so no turn of the task could commit again.
  test "discard! removes a repository written into a worktree, so the next commit works" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      nested = dir.join("designs/x/.git")
      FileUtils.mkdir_p([ nested.join("objects"), nested.join("refs") ])
      nested.join("HEAD").write("ref: refs/heads/master\n")
      assert_raises(GitRunner::Error) { repo.stage_all!(dir) }

      repo.discard!(dir)

      assert_not dir.join("designs/x").exist?
      assert commit_files(repo, dir, { "designs/a.html" => "a" })
    end
  end

  test "remote_head is where origin's branch was at the last fetch, and nil when origin has none" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      push_from_elsewhere(remote, "design/REC-1", { "designs/a.html" => "a" })
      assert_nil repo.remote_head("design/REC-1"), "not fetched yet"
      repo.ensure_clone!
      assert_equal remote_branch_sha(remote, "design/REC-1"), repo.remote_head("design/REC-1")
      assert_nil repo.head("design/REC-1"), "origin's branch is not a local one"
      assert_nil repo.remote_head("design"), "a folder of branches is no branch"
      assert_nil repo.remote_head("design/REC-2")
    end
  end

  test "indexed? sees a file in a checkout's index at exactly the path given" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      assert repo.indexed?(dir, "runtime/flosis.js")
      assert_not repo.indexed?(dir, "runtime"), "a folder is not a file"
      assert_not repo.indexed?(dir, "runtime/flosis")
      assert_not repo.indexed?(dir, "runtime/*.js"), "a path, not a pattern"

      dir.join("runtime/flosis.js").delete
      assert repo.indexed?(dir, "runtime/flosis.js"), "deleted but not staged yet"
      repo.stage_all!(dir)
      assert_not repo.indexed?(dir, "runtime/flosis.js")
      assert repo.indexed?(repo.root, "runtime/flosis.js"), "each checkout has an index of its own"
    end
  end

  test "remove_worktree! deletes a worktree's folder and git's record of it, so the branch is checked out afresh" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      sha = commit_files(repo, dir, { "designs/a.html" => "a" })
      File.write(dir.join("designs/b.html"), "uncommitted")
      dir.join(".git").write("gitdir: /nowhere\n")

      repo.remove_worktree!(dir)

      assert_not dir.exist?
      assert_not_includes GitRunner.run!("worktree", "list", "--porcelain", chdir: repo.root), "wip__REC-1"
      assert_equal sha, repo.head("wip/REC-1"), "the branch keeps its commits"
      assert_equal dir, repo.worktree!("wip/REC-1")
      assert dir.join("designs/a.html").exist?
      assert_not dir.join("designs/b.html").exist?
    end
  end

  # Decided by the path alone: git is not asked about a folder whose link
  # may be lying.
  test "remove_worktree! removes nothing but a folder directly in the worktrees folder" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      app = repo.root.dirname.join("app")
      FileUtils.mkdir_p(app)
      File.write(app.join("work.rb"), "keep me")

      [ repo.root, repo.worktrees_root, app, dir.join("designs"), repo.worktrees_root.join("wip__REC-1", ".."),
        "#{repo.worktrees_root}/../app" ].each do |path|
        assert_raises(ArgumentError, path.to_s) { repo.remove_worktree!(path) }
      end
      assert repo.root.join(".git").exist?
      assert dir.join("README.md").exist?
      assert app.join("work.rb").exist?
    end
  end

  # Rotating a project's preview token builds a Repo for a project that may
  # have no folder at all yet, and must not make one.
  test "building a repo names its remote and touches neither the disk nor the project" do
    project = projects(:plain_project)
    project.design_repo = "acme/designs"
    project.define_singleton_method(:designs_dir) { raise "the folders resolve on first use, not when the repo is built" }
    assert_equal "https://github.com/acme/designs.git", Designs::Repo.new(project).remote_url
    with_remote_url("/srv/fake.git") { assert_equal "/srv/fake.git", Designs::Repo.new(project).remote_url }
    assert_nil project.reload.workspace_dir
  end

  # For Elvium, workspace_dir is the app checkout itself.
  test "a legacy Elvium project's design repo stays out of the app checkout" do
    project = projects(:jira_project)
    project.workspace_dir = Project::ELVIUM_LEGACY_DIR
    root = Designs::Repo.new(project, remote_url: "unused").root
    assert_equal Pathname(project.designs_dir).join("design-repo"), root
    assert_not root.to_s.start_with?(Project::ELVIUM_LEGACY_DIR)
  end

  test "merge_master_into! makes a merge commit when nothing collides" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/a.html" => "a\n" })
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/b.html" => "b\n" })
      commit_files(repo, repo.root, { "designs/c.html" => "c\n" })
      assert_equal [], repo.merge_master_into!(dir)
      assert dir.join("designs/c.html").exist?
      assert_equal [ repo.head("master") ],
                   GitRunner.run!("rev-list", "--parents", "-1", "HEAD", chdir: dir).split.drop(2)
    end
  end

  test "merge_master_into! names the files that collide and leaves them marked for resolving" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/a.html" => "base\n", "designs/b.html" => "base\n" })
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/a.html" => "task\n", "designs/b.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n", "designs/b.html" => "master\n", "designs/c.html" => "c\n" })
      assert_equal %w[designs/a.html designs/b.html], repo.merge_master_into!(dir).sort
      assert_match(/^<<<<<<< /, dir.join("designs/a.html").read)
      assert dir.join("designs/c.html").exist?
      assert GitRunner.run!("rev-parse", "--verify", "--quiet", "MERGE_HEAD", chdir: dir).present?
    end
  end

  test "commit! records a merge in progress whose result is the branch as it was" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/a.html" => "base\n" })
      dir = repo.worktree!("wip/REC-1")
      wip = commit_files(repo, dir, { "designs/a.html" => "task\n" })
      commit_files(repo, repo.root, { "designs/a.html" => "master\n" })
      repo.merge_master_into!(dir)
      dir.join("designs/a.html").write("task\n")
      repo.stage_all!(dir)
      sha = repo.commit!(dir, message: "keep the task's version")
      assert_equal [ wip, repo.head("master") ], GitRunner.run!("rev-list", "--parents", "-1", sha, chdir: dir).split.drop(1)
    end
  end

  test "an atomic push updates no ref on the remote when one of them is refused" do
    with_design_remote do |repo, remote|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      first = commit_files(repo, dir, { "designs/a.html" => "1" })
      repo.tag!("approved/REC-1/1", at: first)
      repo.push!("approved/REC-1/1")
      second = commit_files(repo, dir, { "designs/a.html" => "2" })
      GitRunner.run!("tag", "--force", "approved/REC-1/1", second, chdir: repo.root)
      repo.point!("design/REC-1", to: second)
      assert_raises(GitRunner::Error) { repo.push!("design/REC-1", "approved/REC-1/1", atomic: true) }
      assert_nil remote_branch_sha(remote, "design/REC-1")
    end
  end

  # Ruling P2-R26: the screen reads refs while a job may hold the lock.
  test "head and commits_ahead read without the lock when asked to" do
    with_design_remote do |repo, _|
      master = seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      commit_files(repo, dir, { "designs/a.html" => "1" })
      File.open(repo.root.dirname.join("design-repo.lock")) do |job|
        job.flock(File::LOCK_EX)
        Timeout.timeout(10) do
          assert_equal master, repo.head("master", lock: false)
          assert_equal 1, repo.commits_ahead("wip/REC-1", lock: false)
        end
      end
    end
  end

  test "delete_tag! deletes a tag here, and on origin when asked to" do
    with_design_remote do |repo, remote|
      master = seed_master(repo)
      repo.tag!("approved/X-1/1", at: master)
      repo.tag!("approved/X-1/2", at: master)
      repo.push!("approved/X-1/1", "approved/X-1/2")
      repo.delete_tag!("approved/X-1/1")
      repo.delete_tag!("approved/X-1/2", remote: true)
      assert_equal [], repo.tags("approved/X-1/*")
      assert_equal "approved/X-1/1", GitRunner.run!("tag", "-l", "approved/*", chdir: remote).strip
    end
  end
end
