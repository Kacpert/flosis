require "test_helper"

class Designs::PublisherTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example"
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    ENV.delete("DESIGNS_PREVIEW_URL")
    FileUtils.remove_entry(@preview_root)
  end

  test "publishing master puts its files under the project's token, readable by Apache" do
    with_design_remote do |repo, _|
      seed_master(repo, { "index.html" => "<h1>Home</h1>", "designs/jobs.html" => "<p>Jobs</p>" })
      dir = Designs::Publisher.new(repo.project, repo).publish!("master", "master")
      token = repo.project.reload.design_preview_token
      assert_equal Pathname(@preview_root).join(token, "master"), dir
      assert_equal "<h1>Home</h1>", dir.join("index.html").read
      assert_equal "644", format("%o", dir.join("designs/jobs.html").stat.mode & 0o777)
      assert_equal "755", format("%o", dir.join("designs").stat.mode & 0o777)
    end
  end

  test "republishing replaces the slot and leaves nothing else behind" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/old.html" => "old" })
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      FileUtils.rm(repo.root.join("designs/old.html"))
      commit_files(repo, repo.root, { "designs/new.html" => "new" })
      dir = publisher.publish!("master", "master")
      assert_not dir.join("designs/old.html").exist?
      assert dir.join("designs/new.html").exist?
      assert_equal [ "master" ], Dir.children(dir.dirname)
    end
  end

  test "a work-in-progress slot lives under wip/" do
    with_design_remote do |repo, _|
      seed_master(repo)
      repo.worktree!("wip/REC-1")
      dir = Designs::Publisher.new(repo.project, repo).publish!("wip/REC-1", "wip/REC-1")
      assert_equal "wip/REC-1", dir.relative_path_from(Pathname(@preview_root).join(repo.project.design_preview_token)).to_s
    end
  end

  test "slots that could escape the token folder are refused" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      %w[../x wip/../../x master/../x .staging x/y].each do |slot|
        assert_raises(ArgumentError, slot) { publisher.publish!("master", slot) }
      end
    end
  end

  test "urls carry the token, the slot, the page and the contexts" do
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    publisher = Designs::Publisher.new(project, nil)
    assert_equal "https://preview.example/t0k/REC-1/designs/jobs.html?ctx=admin,workshop",
                 publisher.url("REC-1", "designs/jobs.html", ctx: %w[admin workshop])
    assert_equal "https://preview.example/t0k/master/index.html", publisher.url("master")
  end

  test "rotate_token! moves the previews and kills the old path" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      old = repo.project.reload.design_preview_token
      new = publisher.rotate_token!
      assert_not_equal old, new
      assert_not File.exist?(File.join(@preview_root, old))
      assert File.exist?(File.join(@preview_root, new, "master", "README.md"))
    end
  end

  # Beyond the brief.

  test "the preview root and host come from the environment, and fall back to the development ones when unset or blank" do
    ENV["DESIGNS_PREVIEW_ROOT"] = ""
    ENV["DESIGNS_PREVIEW_URL"] = ""
    assert_equal Rails.root.join("tmp/designs_preview"), Designs::Publisher.root
    assert_equal "http://localhost:3100", Designs::Publisher.base_url

    ENV["DESIGNS_PREVIEW_ROOT"] = "~/previews"
    assert_equal Pathname(Dir.home).join("previews"), Designs::Publisher.root
  end

  test "a slot is matched whole: a newline cannot hide a path behind a valid line" do
    publisher = Designs::Publisher.new(projects(:jira_project), nil)
    [ "master\n", "master\n../../x", "x\nwip/y" ].each do |slot|
      assert_raises(ArgumentError, slot.inspect) { publisher.publish!("master", slot) }
    end
  end

  test "an escaped context value cannot split into two, and a trailing slash on the host is not doubled" do
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example/"
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    assert_equal "https://preview.example/t0k/master/index.html?ctx=a%2Cb,c+d%26e",
                 Designs::Publisher.new(project, nil).url("master", ctx: [ "a,b", "c d&e" ])
  end

  test "every folder and file Apache serves is open to it, whatever umask the host runs with" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/jobs.html" => "<p>Jobs</p>" })
      script = repo.root.join("runtime/run.sh")
      FileUtils.mkdir_p(script.dirname)
      File.write(script, "#!/bin/sh\n")
      File.chmod(0o755, script)
      repo.stage_all!(repo.root)
      repo.commit!(repo.root, message: "an executable")
      repo.worktree!("wip/REC-1")

      publisher = Designs::Publisher.new(repo.project, repo)
      mode = ->(path) { format("%o", path.stat.mode & 0o777) }

      # The project's first publish goes into wip/, so nothing but the publish
      # itself opens the token folder: a slot directly under it would too.
      wip = with_umask(0o027) { publisher.publish!("wip/REC-1", "wip/REC-1") }
      [ wip.dirname.dirname, wip.dirname, wip ].each { |folder| assert_equal "755", mode.(folder), folder.to_s }

      master = with_umask(0o027) { publisher.publish!("master", "master") }
      assert_equal [ "designs", "runtime" ], Dir.children(master).sort
      [ master, master.join("designs"), master.join("runtime") ].each { |folder| assert_equal "755", mode.(folder), folder.to_s }
      [ master.join("designs/jobs.html"), master.join("runtime/run.sh"), wip.join("designs/jobs.html") ].each do |file|
        assert_equal "644", mode.(file), file.to_s
      end
    end
  end

  test "symlinks in the repo are not published, whatever they point at, and are never followed" do
    with_design_remote do |repo, _|
      outside = Dir.mktmpdir("outside")
      begin
        secret = File.join(outside, "secret.txt")
        File.write(secret, "keep out")
        File.chmod(0o600, secret)
        seed_master(repo, { "designs/ok.html" => "<p>ok</p>" })
        FileUtils.mkdir_p(repo.root.join("designs/deep/er"))
        File.symlink("/etc/passwd", repo.root.join("designs/leak"))
        File.symlink(secret, repo.root.join("designs/deep/er/secret"))
        File.symlink(outside, repo.root.join("designs/outside"))
        File.symlink("ok.html", repo.root.join("designs/alias.html"))
        repo.stage_all!(repo.root)
        repo.commit!(repo.root, message: "links")

        dir = Designs::Publisher.new(repo.project, repo).publish!("master", "master")

        assert_equal "<p>ok</p>", dir.join("designs/ok.html").read
        %w[designs/leak designs/deep/er/secret designs/outside designs/alias.html].each do |link|
          assert_not File.symlink?(dir.join(link)), "#{link} was published as a link"
          assert_not dir.join(link).exist?, "#{link} was published"
        end
        assert_equal "600", format("%o", File.stat(secret).mode & 0o777), "a link was followed by chmod"
        assert_equal "keep out", File.read(secret)
      ensure
        FileUtils.remove_entry(outside)
      end
    end
  end

  test "a project instance whose token is out of date publishes under the stored one" do
    with_design_remote do |repo, _|
      seed_master(repo)
      project = repo.project
      project.update_column(:design_preview_token, "old-token-old-token-old-token-12")
      stale = Project.find(project.id)
      Project.where(id: project.id).update_all(design_preview_token: "new-token-new-token-new-token-12")

      dir = Designs::Publisher.new(stale, repo).publish!("master", "master")

      assert_equal Pathname(@preview_root).join("new-token-new-token-new-token-12", "master"), dir
      assert_equal [ "new-token-new-token-new-token-12" ], Dir.children(@preview_root)
    end
  end

  test "a project instance loaded before the token existed does not make a second one" do
    with_design_remote do |repo, _|
      seed_master(repo)
      stale = Project.find(repo.project.id)
      token = Project.find(repo.project.id).ensure_design_preview_token!

      dir = Designs::Publisher.new(stale, repo).publish!("master", "master")

      assert_equal Pathname(@preview_root).join(token, "master"), dir
      assert_equal token, Project.find(repo.project.id).design_preview_token
    end
  end

  test "publishing runs inside the repo's lock" do
    with_design_remote do |repo, _|
      seed_master(repo)
      seen = probing_lock(repo) { Dir.glob(File.join(@preview_root, "*", "master", "README.md")).any? }
      Designs::Publisher.new(repo.project, repo).publish!("master", "master")
      assert_equal [ false, true ], seen
    end
  end

  test "a branch the repo does not have is refused before anything is written" do
    with_design_remote do |repo, _|
      seed_master(repo)
      assert_raises(ArgumentError) { Designs::Publisher.new(repo.project, repo).publish!("wip/NOPE-1", "wip/NOPE-1") }
      assert_empty Dir.children(@preview_root)
    end
  end

  test "a failed unpacking raises, keeps the live copy and leaves no half-published folder" do
    with_design_remote do |repo, _|
      seed_master(repo, { "index.html" => "v1" })
      publisher = Designs::Publisher.new(repo.project, repo)
      dir = publisher.publish!("master", "master")
      token = repo.project.reload.design_preview_token
      commit_files(repo, repo.root, { "index.html" => "v2" })

      error = with_failing_tar do |bin|
        raised = assert_raises(Designs::Publisher::Error) { publisher.publish!("master", "master") }
        # Apache refuses (^|/).staging- and .old- paths, so the names are part of the contract.
        assert_match(/\A\.staging-\h+\z/, File.basename(File.read(File.join(bin, "cwd")).strip))
        # The token is the only thing that keeps previews private: not in a process list.
        assert_not_includes File.read(File.join(bin, "argv")), token
        raised
      end

      assert_includes error.message, "tar: boom"
      assert_equal "v1", dir.join("index.html").read
      assert_equal [ "master" ], Dir.children(dir.dirname)
    end
  end

  test "a swap that fails halfway puts the live copy back" do
    with_design_remote do |repo, _|
      seed_master(repo, { "index.html" => "v1" })
      publisher = Designs::Publisher.new(repo.project, repo)
      dir = publisher.publish!("master", "master")
      commit_files(repo, repo.root, { "index.html" => "v2" })

      moves = []
      renames = File.method(:rename)
      File.define_singleton_method(:rename) do |from, to|
        moves << to
        raise Errno::EIO, "disk" if moves.size == 2
        renames.call(from, to)
      end
      begin
        assert_raises(Errno::EIO) { publisher.publish!("master", "master") }
      ensure
        File.define_singleton_method(:rename, renames)
      end

      assert_match(/\A\.old-\h+\z/, File.basename(moves.first))
      assert_equal "v1", dir.join("index.html").read
      assert_equal [ "master" ], Dir.children(dir.dirname)
    end
  end

  test "rotating from an out-of-date instance still kills the links that are live" do
    with_design_remote do |repo, _|
      seed_master(repo)
      Designs::Publisher.new(repo.project, repo).publish!("master", "master")
      stale = Project.find(repo.project.id)
      # Another process rotates first: the folder and the stored token move on.
      live = Designs::Publisher.new(Project.find(repo.project.id), repo).rotate_token!

      new = Designs::Publisher.new(stale, repo).rotate_token!

      assert_not_equal live, new
      assert_equal [ new ], Dir.children(@preview_root)
      assert File.exist?(File.join(@preview_root, new, "master", "README.md"))
    end
  end

  test "rotating a project with no folder yet takes no lock and makes no folders" do
    project = projects(:jira_project)
    assert_nil project.workspace_dir, "fixture drifted: this project must have no folder of its own"
    project.update_column(:design_preview_token, "old-token-old-token-old-token-12")
    old_slot = File.join(@preview_root, "old-token-old-token-old-token-12", "master")
    FileUtils.mkdir_p(old_slot)
    File.write(File.join(old_slot, "index.html"), "hi")
    repo = Designs::Repo.new(project, remote_url: "unused")
    repo.define_singleton_method(:synchronize) { |&_| raise "rotation took the repo's lock" }

    new = Designs::Publisher.new(project, repo).rotate_token!

    assert_equal new, project.reload.design_preview_token
    assert_equal "hi", File.read(File.join(@preview_root, new, "master", "index.html"))
    assert_not File.exist?(File.join(@preview_root, "old-token-old-token-old-token-12"))
    assert_nil project.workspace_dir

    # A publisher with no repo at all rotates the same way.
    again = Designs::Publisher.new(project, nil).rotate_token!
    assert File.exist?(File.join(@preview_root, again, "master", "index.html"))
  end

  test "rotating a project that has a clone moves the previews inside the repo's lock" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      old = Pathname(@preview_root).join(repo.project.reload.design_preview_token)

      seen = probing_lock(repo) { old.exist? }
      publisher.rotate_token!

      assert_equal [ true, false ], seen
    end
  end

  test "rotating before anything was published only stores the new token" do
    project = projects(:jira_project)
    assert_nil project.design_preview_token, "fixture drifted: this project must have no token yet"

    token = Designs::Publisher.new(project, nil).rotate_token!

    assert_equal token, project.reload.design_preview_token
    assert_empty Dir.children(@preview_root)
  end

  test "a rotation whose new token cannot be stored puts the previews back under the old one" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      old = repo.project.reload.design_preview_token
      repo.project.define_singleton_method(:update_column) { |*| raise ActiveRecord::StatementInvalid, "gone away" }

      assert_raises(ActiveRecord::StatementInvalid) { publisher.rotate_token! }

      assert_equal [ old ], Dir.children(@preview_root)
      assert File.exist?(File.join(@preview_root, old, "master", "README.md"))
    end
  end

  private

  # What `probe` finds on entering and on leaving the repo's lock. Only the
  # outermost hold counts: the git calls inside take the lock again.
  def probing_lock(repo, &probe)
    seen = []
    holds = 0
    lock = repo.method(:synchronize)
    repo.define_singleton_method(:synchronize) do |&block|
      holds += 1
      seen << probe.call if holds == 1
      lock.call(&block).tap { seen << probe.call if holds == 1 }
    ensure
      holds -= 1
    end
    seen
  end

  def with_umask(mask)
    previous = File.umask(mask)
    yield
  ensure
    File.umask(previous)
  end

  # A `tar` that fails, first in the PATH. It notes where it ran and what it
  # was asked, in files beside it.
  def with_failing_tar
    bin = Dir.mktmpdir("fake-tar")
    path = ENV["PATH"]
    File.write(File.join(bin, "tar"), <<~SH)
      #!/bin/sh
      pwd > "#{bin}/cwd"
      echo "$@" > "#{bin}/argv"
      echo "tar: boom" >&2
      exit 2
    SH
    File.chmod(0o755, File.join(bin, "tar"))
    ENV["PATH"] = "#{bin}:#{path}"
    yield bin
  ensure
    ENV["PATH"] = path
    FileUtils.remove_entry(bin)
  end
end
