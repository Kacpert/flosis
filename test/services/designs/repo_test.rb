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

  test "synchronize is re-entrant within a thread, across Repo objects of one project" do
    with_design_remote do |repo, _|
      other = Designs::Repo.new(repo.project, remote_url: repo.remote_url)
      assert_equal :inside, Timeout.timeout(5) { repo.synchronize { other.synchronize { :inside } } }
    end
  end

  test "commits and merges are Flosis's, in worktrees too" do
    with_design_remote do |repo, _|
      seed_master(repo)
      wip = commit_files(repo, repo.worktree!("wip/REC-1"), { "designs/a.html" => "a" })
      repo.point!("design/REC-1", to: wip)
      merged = repo.merge_into_master!("design/REC-1", message: "Approve REC-1")
      [ wip, merged ].each do |sha|
        assert_equal "Flosis <designs@flosis.com> / Flosis <designs@flosis.com>",
                     GitRunner.run!("log", "-1", "--format=%an <%ae> / %cn <%ce>", sha, chdir: repo.root).strip
      end
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
end
