require "test_helper"

class Designs::AppCopyTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  # Writes the files into dir and commits them, making dir a repository first
  # if it is not one yet.
  def commit_all(dir, files)
    system("git", "-C", dir, "init", "-q", exception: true) unless File.exist?(File.join(dir, ".git"))
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), body)
    end
    system("git", "-C", dir, "add", "-A", exception: true)
    system("git", "-C", dir, "-c", "user.name=Dev", "-c", "user.email=dev@example.com", "commit", "-q", "-m", "app",
           exception: true)
  end

  # A copy as a turn leaves it when it is killed: sealed, and last touched
  # age ago.
  def leaked_copy(age)
    holder = Dir.mktmpdir(Designs::AppCopy::PREFIX)
    FileUtils.mkdir(File.join(holder, "app"))
    File.write(File.join(holder, "app/routes.rb"), "get '/jobs'\n")
    File.chmod(0o444, File.join(holder, "app/routes.rb"))
    File.chmod(0o555, File.join(holder, "app"))
    File.utime(age.ago.to_time, age.ago.to_time, holder)
    holder
  end

  def remove_copy(holder)
    return unless holder && File.exist?(holder)

    FileUtils.chmod_R("u+w", holder)
    FileUtils.remove_entry(holder)
  end

  # Ruling P2-R19: Claude reads the app through this copy, and never through
  # the live checkout, which is shared (and for Elvium a developer's own).
  test "a copy holds what the checkout has committed, read-only, and nothing it does not track" do
    app = checkout!(@project)
    commit_all(app, { "config/routes.rb" => "get '/jobs'\n" })
    File.write(File.join(app, ".env"), "SECRET_KEY_BASE=abc\n")
    File.write(File.join(app, "config/routes.rb"), "an edit nobody committed\n")

    Designs::AppCopy.open(@project) do |copy|
      assert_not_equal File.realpath(app), File.realpath(copy)
      assert_equal "get '/jobs'\n", File.read(File.join(copy, "config/routes.rb"))
      assert_not File.exist?(File.join(copy, ".env")), "what the checkout does not track"
      assert_not File.exist?(File.join(copy, ".git"))
      assert_equal 0o444, File.stat(File.join(copy, "config/routes.rb")).mode & 0o777
      assert_equal [ 0o555 ], [ copy, File.join(copy, "config") ].map { |dir| File.stat(dir).mode & 0o777 }.uniq
      unless Process.uid.zero?
        assert_raises(Errno::EACCES) { File.write(File.join(copy, "config/routes.rb"), "hacked") }
        assert_raises(Errno::EACCES) { File.write(File.join(copy, "hacked.rb"), "x") }
      end
    end
  end

  test "the checkout is left as it was" do
    app = checkout!(@project)
    commit_all(app, { "config/routes.rb" => "get '/jobs'\n" })
    File.write(File.join(app, ".env"), "SECRET_KEY_BASE=abc\n")
    File.write(File.join(app, "config/routes.rb"), "an edit nobody committed\n")
    status = GitRunner.run!("status", "--porcelain", chdir: app)

    Designs::AppCopy.open(@project) { |copy| assert copy }

    assert_equal status, GitRunner.run!("status", "--porcelain", chdir: app)
    assert_equal "SECRET_KEY_BASE=abc\n", File.read(File.join(app, ".env"))
    assert_equal "an edit nobody committed\n", File.read(File.join(app, "config/routes.rb"))
  end

  test "the copy and the folder it was made in are removed when the block is done, however it ends" do
    commit_all(checkout!(@project), { "Gemfile" => "gem \"rails\"\n" })

    copy = Designs::AppCopy.open(@project) { |dir| dir }
    assert copy
    assert_not File.exist?(File.dirname(copy))

    raised_in = nil
    assert_raises(RuntimeError) { Designs::AppCopy.open(@project) { |dir| raised_in = dir; raise "boom" } }
    assert raised_in
    assert_not File.exist?(File.dirname(raised_in))
  end

  # A link the app's repo tracks would lead Claude's tools out of the copy:
  # this one to the live checkout's .env.
  test "the copy holds no links" do
    app = checkout!(@project)
    File.symlink(File.join(app, ".env"), File.join(app, "settings.txt"))
    commit_all(app, { "Gemfile" => "gem \"rails\"\n" })
    File.write(File.join(app, ".env"), "SECRET_KEY_BASE=abc\n")
    assert_equal "Gemfile\nsettings.txt\n", GitRunner.run!("ls-files", chdir: app)

    Designs::AppCopy.open(@project) { |copy| assert_equal [ "Gemfile" ], Dir.children(copy) }
  end

  test "a project with no checkout, or one with nothing committed, gets no copy" do
    Designs::AppCopy.open(@project) { |copy| assert_nil copy }

    system("git", "-C", checkout!(@project), "init", "-q", exception: true)
    Designs::AppCopy.open(@project) { |copy| assert_nil copy }
  end

  # Ruling P2-R30. git answers for the repository a folder is in, wherever
  # that is: in a folder inside another repository (Flosis's own code, say),
  # git archive would copy that repository's files.
  test "a folder inside another repository is no checkout of its own, and gets no copy" do
    outer = Dir.mktmpdir("outer")
    commit_all(outer, { "app/routes.rb" => "the outer repository's\n", "config/master.key" => "outer-key\n" })
    @project.update_columns(workspace_dir: outer, github_repo: "acme/app")
    assert_equal File.join(outer, "app"), @project.ai_codebase_path

    Designs::AppCopy.open(@project) { |copy| assert_nil copy }
  ensure
    FileUtils.remove_entry(outer) if outer
  end

  # Ruling P2-R30. Solid Queue stops a worker with exit!, which runs no
  # ensure, so a turn a deploy killed leaves its copy behind.
  test "sweep removes a copy left behind longer ago than it is told, and keeps a younger one" do
    old = leaked_copy(2.hours)
    young = leaked_copy(1.minute)

    Designs::AppCopy.sweep(older_than: 1.hour.ago)

    assert_not File.exist?(old)
    assert File.exist?(File.join(young, "app/routes.rb"))
  ensure
    [ old, young ].each { |holder| remove_copy(holder) }
  end

  test "sweep follows no link named like a copy" do
    target = Dir.mktmpdir("kept")
    File.write(File.join(target, "work.rb"), "keep me\n")
    link = File.join(Dir.tmpdir, "#{Designs::AppCopy::PREFIX}-link-#{SecureRandom.hex(4)}")
    File.symlink(target, link)
    File.lutime(2.hours.ago.to_time, 2.hours.ago.to_time, link)

    Designs::AppCopy.sweep(older_than: 1.hour.ago)

    assert File.exist?(File.join(target, "work.rb"))
  ensure
    File.unlink(link) if link && File.symlink?(link)
    FileUtils.remove_entry(target) if target
  end
end
