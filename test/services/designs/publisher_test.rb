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
      # A bare wip would replace the wip/ folder, and every work in progress with it.
      %w[../x wip/../../x master/../x .staging x/y wip].each do |slot|
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

  test "the slot pattern takes master, a key, wip/setup and wip/<key>, but not the wip folder itself or a path" do
    %w[master REC-1 task-12 wip/setup wip/REC-1 wip/wip wip-1 wipe].each do |slot|
      assert_match Designs::Publisher::SLOT, slot
    end
    %w[wip wip/ /wip wip//x ../x].each do |slot|
      assert_no_match Designs::Publisher::SLOT, slot
    end
  end

  test "a slot is matched whole: a newline cannot hide a path behind a valid line" do
    publisher = Designs::Publisher.new(projects(:jira_project), nil)
    [ "master\n", "master\n../../x", "x\nwip/y" ].each do |slot|
      assert_raises(ArgumentError, slot.inspect) { publisher.publish!("master", slot) }
    end
  end

  test "a link survives file names with spaces, #, ?, % and letters beyond ASCII, and keeps its folders" do
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    publisher = Designs::Publisher.new(project, nil)
    {
      "designs/job offers.html" => "designs/job%20offers.html",
      "designs/a#b?c%d.html" => "designs/a%23b%3Fc%25d.html",
      "designs/żółć.html" => "designs/%C5%BC%C3%B3%C5%82%C4%87.html",
      "designs/" => "designs/"
    }.each do |path, escaped|
      assert_equal "https://preview.example/t0k/REC-1/#{escaped}", publisher.url("REC-1", path), path
    end
    assert_equal "https://preview.example/t0k/wip/REC-1/a%20b.html?ctx=admin", publisher.url("wip/REC-1", "a b.html", ctx: [ "admin" ])
  end

  test "a link to something that is not a slot is refused, as publishing it would be" do
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    publisher = Designs::Publisher.new(project, nil)
    [ "wip", "../x", "design/REC-1", "REC 1", "master\n" ].each do |slot|
      assert_raises(ArgumentError, slot.inspect) { publisher.url(slot) }
    end
  end

  test "a trailing slash on the host is not doubled" do
    ENV["DESIGNS_PREVIEW_URL"] = "https://preview.example/"
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    assert_equal "https://preview.example/t0k/master/index.html?ctx=admin,client_2,dark-mode",
                 Designs::Publisher.new(project, nil).url("master", ctx: %w[admin client_2 dark-mode])
  end

  # Context ids are letters, digits, _ and - (the design repo's README says
  # so), so a context that is anything else is no context a page knows: it is
  # refused rather than escaped into one value or split into two.
  test "a context that is not letters, digits, _ or - is refused" do
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    publisher = Designs::Publisher.new(project, nil)
    [ "a,b", "c d", "x&y", "", "żółw", "a/b", "admin\n", "a=b" ].each do |value|
      assert_raises(ArgumentError, value.inspect) { publisher.url("master", ctx: [ "admin", value ]) }
    end
  end

  # A manifest's page path goes into Jira links. One that walks out of its slot
  # (../wip/REC-1/x.html under an approved REC-1) would show work in progress
  # to whoever has the link.
  test "a link to a page outside its slot is refused" do
    project = projects(:jira_project)
    project.update!(design_preview_token: "t0k")
    publisher = Designs::Publisher.new(project, nil)
    [ "../wip/REC-1/x.html", "designs/../../wip/REC-1/x.html", "..", ".", "./index.html", "designs/./x.html",
      "/index.html", "/" ].each do |path|
      assert_raises(ArgumentError, path) { publisher.url("REC-1", path) }
    end
    assert_equal "https://preview.example/t0k/REC-1/designs/..x.html", publisher.url("REC-1", "designs/..x.html"),
                 "dots inside a name are the name"
  end

  # The development defaults are wrong in production, not merely unset:
  # previews written under the app's tmp/, which Apache does not serve, and
  # localhost links sent to Jira.
  test "in production an unset preview root or host raises instead of falling back" do
    ENV["DESIGNS_PREVIEW_ROOT"] = ""
    ENV["DESIGNS_PREVIEW_URL"] = " "
    in_production do
      error = assert_raises(Designs::Publisher::Error) { Designs::Publisher.root }
      assert_includes error.message, "DESIGNS_PREVIEW_ROOT"
      error = assert_raises(Designs::Publisher::Error) { Designs::Publisher.base_url }
      assert_includes error.message, "DESIGNS_PREVIEW_URL"

      ENV["DESIGNS_PREVIEW_ROOT"] = "/srv/previews"
      ENV["DESIGNS_PREVIEW_URL"] = "https://previews.example/"
      assert_equal Pathname("/srv/previews"), Designs::Publisher.root
      assert_equal "https://previews.example", Designs::Publisher.base_url
    end
  end

  test "every folder and file Apache serves is open to it, whatever umask the host runs with" do
    with_design_remote do |repo, _|
      seed_master(repo, { "designs/jobs.html" => "<p>Jobs</p>" })
      script = repo.root.join("runtime/run.js")
      FileUtils.mkdir_p(script.dirname)
      File.write(script, "#!/usr/bin/env node\n")
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
      [ master.join("designs/jobs.html"), master.join("runtime/run.js"), wip.join("designs/jobs.html") ].each do |file|
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

  test "only static web files are published: no dotfiles, no dot folders, no scripts" do
    with_design_remote do |repo, _|
      seed_master(repo, {
        "README.md" => "hi\n",
        "designs/page.html" => "<p>page</p>",
        "designs/.htaccess" => "AddHandler application/x-httpd-php .html\n",
        "designs/.config.json" => "{}\n",
        "designs/x/.user.ini" => "auto_prepend_file=/etc/passwd\n",
        "designs/shell.php" => "<?php system($_GET['c']);\n",
        "runtime/a.cgi" => "#!/bin/sh\n",
        "design_system/.hidden/a.css" => "a { color: red }\n",
        "design_system/tokens.css" => "b { color: blue }\n",
        "designs/deep/.cache/inner/c.css" => "c { color: green }\n"
      })

      dir = Designs::Publisher.new(repo.project, repo).publish!("master", "master")

      assert_equal [ "README.md", "design_system/tokens.css", "designs/page.html", "runtime/flosis.js" ], published_files(dir)
      assert_not dir.join("design_system/.hidden").exist?, "a dot folder was published"
      assert_not dir.join("designs/deep/.cache").exist?, "a nested dot folder was published"
    end
  end

  test "the static web kinds are published whatever the case of their extension, every other kind is not" do
    served = %w[html htm css js mjs json map svg png jpg jpeg gif webp avif ico woff woff2 ttf otf txt md pdf mp4 webm]
    refused = %w[php phtml php5 phar cgi pl py rb sh exe zip gz xml yml ts jsx scss wasm]
    kept = served.map { |ext| "designs/file.#{ext}" } + %w[designs/UPPER.HTML designs/Mixed.JpG designs/app.min.js]
    dropped = refused.map { |ext| "designs/file.#{ext}" } + %w[designs/LICENSE designs/archive.tar.gz]

    with_design_remote do |repo, _|
      seed_master(repo, (kept + dropped).index_with { "x" })

      dir = Designs::Publisher.new(repo.project, repo).publish!("master", "master")

      assert_equal [ *kept, "runtime/flosis.js" ].sort, published_files(dir)
    end
  end

  test "a script hidden behind a second extension is never published" do
    scripts = %w[php php3 php4 php5 php6 php7 php8 phtml phar cgi pl py sh asp aspx jsp shtml shtm stm pht phps fcgi]
    hidden = scripts.map { |ext| "designs/x.#{ext}.html" } +
             %w[designs/shell.php.html designs/a.PHP5.css designs/x.cgi.png designs/v1.php.min.js designs/Shell.ASPX.png]
    # Segments are matched whole, and only after the first dot: a name that merely
    # starts with, or contains, a script word is a design like any other.
    kept = %w[designs/brand.png designs/page.html designs/php-guide.html designs/php.html designs/sh.png
              designs/app.phpx.css designs/a.shell.css designs/jquery.min.js]

    with_design_remote do |repo, _|
      seed_master(repo, (hidden + kept).index_with { "x" })

      dir = Designs::Publisher.new(repo.project, repo).publish!("master", "master")

      assert_equal [ *kept, "runtime/flosis.js" ].sort, published_files(dir)
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

  test "publishing a project with no folder yet raises, takes no lock and makes no folders" do
    project = projects(:jira_project)
    assert_nil project.workspace_dir, "fixture drifted: this project must have no folder of its own"
    repo = Designs::Repo.new(project, remote_url: "unused")
    repo.define_singleton_method(:synchronize) { |&_| raise "publishing took the repo's lock" }

    assert_raises(Designs::Publisher::Error) { Designs::Publisher.new(project, repo).publish!("master", "master") }

    assert_nil project.reload.workspace_dir
    assert_empty Dir.children(@preview_root)
  end

  test "publishing goes by the folder on the project's row, not by an instance that remembers one the row has lost" do
    dir = Dir.mktmpdir("workspace")
    begin
      project = projects(:jira_project)
      project.update_column(:workspace_dir, dir)
      stale = Project.find(project.id)
      Project.where(id: project.id).update_all(workspace_dir: nil)
      repo = Designs::Repo.new(stale, remote_url: "unused")
      repo.define_singleton_method(:synchronize) { |&_| raise "publishing took the repo's lock" }

      assert_raises(Designs::Publisher::Error) { Designs::Publisher.new(stale, repo).publish!("master", "master") }
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  test "the unpacked copy is private until it has been stripped and opened up" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      seen = []
      strip = publisher.method(:strip_unservable!)
      publisher.define_singleton_method(:strip_unservable!) do |dir|
        seen << format("%o", File.stat(dir).mode & 0o777)
        strip.call(dir)
      end

      with_umask(0o022) { publisher.publish!("master", "master") }

      assert_equal [ "700" ], seen
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

  test "rotating takes the repo's lock when the row has a folder, even if the instance has not heard of it" do
    dir = Dir.mktmpdir("workspace")
    begin
      project = projects(:jira_project)
      project.update_column(:design_preview_token, "old-token-old-token-old-token-12")
      stale = Project.find(project.id)
      Project.where(id: project.id).update_all(workspace_dir: dir)
      old = Pathname(@preview_root).join("old-token-old-token-old-token-12")
      FileUtils.mkdir_p(old.join("master"))
      repo = Designs::Repo.new(stale, remote_url: "unused")
      seen = probing_lock(repo) { old.exist? }

      Designs::Publisher.new(stale, repo).rotate_token!

      assert_equal [ true, false ], seen
      assert_equal dir, Project.find(project.id).workspace_dir, "the stored folder was replaced by a default one"
    ensure
      FileUtils.remove_entry(dir)
    end
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

  # The Designs tab rotates from a web request, which must not wait behind a
  # job that holds the repo: it is told the repo is busy, and nothing moves.
  test "rotating without waiting while a job holds the repo raises Busy and changes nothing" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      publisher.publish!("master", "master")
      old = repo.project.reload.design_preview_token

      File.open(repo.root.dirname.join("design-repo.lock")) do |job|
        job.flock(File::LOCK_EX)
        assert_raises(Designs::Repo::Busy) { publisher.rotate_token!(wait: false) }
      end

      assert_equal old, repo.project.reload.design_preview_token
      assert_equal [ old ], Dir.children(@preview_root)
      assert_not_equal old, publisher.rotate_token!(wait: false), "a free repo rotates without waiting"
    end
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

  # Every file in a slot, relative to it, dotfiles included.
  def published_files(dir)
    Find.find(dir.to_s).select { |path| File.file?(path) }.map { |path| Pathname(path).relative_path_from(dir).to_s }.sort
  end

  # What `probe` finds on entering and on leaving the repo's lock. Only the
  # outermost hold counts: the git calls inside take the lock again.
  def probing_lock(repo, &probe)
    seen = []
    holds = 0
    lock = repo.method(:synchronize)
    repo.define_singleton_method(:synchronize) do |**options, &block|
      holds += 1
      seen << probe.call if holds == 1
      lock.call(**options, &block).tap { seen << probe.call if holds == 1 }
    ensure
      holds -= 1
    end
    seen
  end

  def in_production
    previous = Rails.env
    Rails.env = "production"
    yield
  ensure
    Rails.env = previous
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

  test "published? says whether a slot has been published" do
    with_design_remote do |repo, _|
      seed_master(repo)
      publisher = Designs::Publisher.new(repo.project, repo)
      assert_not publisher.published?("master")
      publisher.publish!("master", "master")
      assert publisher.published?("master")
      assert_not publisher.published?("wip/REC-1")
      assert_raises(ArgumentError) { publisher.published?("../master") }
    end
  end
end
