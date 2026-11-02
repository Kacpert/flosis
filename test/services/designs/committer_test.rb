require "test_helper"

class Designs::CommitterTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  LIBRARY = "Always pair the display serif with a quiet grotesk and keep body copy at sixteen pixels."

  def committer(repo, **guard_options) = Designs::Committer.new(repo, Designs::LeakGuard.new(**guard_options))

  test "a clean change is committed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("designs").tap(&:mkpath).join("index.html"), "<h1>Hi</h1>")
      result = Designs::Committer.new(repo, Designs::LeakGuard.new).commit!(dir, message: "Turn 1")
      assert result.ok?
      assert_equal repo.head("wip/REC-1"), result.sha
    end
  end

  test "a refused change is thrown away and nothing is committed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      FileUtils.mkdir_p(dir.join(".claude"))
      File.write(dir.join(".claude/skill.md"), "secret sauce")
      result = Designs::Committer.new(repo, Designs::LeakGuard.new).commit!(dir, message: "Turn 1")
      assert_not result.ok?
      assert_nil result.sha
      assert_equal before, repo.head("wip/REC-1")
      assert_not dir.join(".claude").exist?
    end
  end

  test "one refused file refuses the whole turn, the clean files with it" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      FileUtils.mkdir_p(dir.join("designs"))
      File.write(dir.join("designs/jobs.html"), "<p>jobs</p>")
      File.write(dir.join("notes.md"), "scratch")
      result = committer(repo).commit!(dir, message: "Turn 1")
      assert_equal [ [ "notes.md", "is outside the design repo's allowed folders" ] ],
                   result.violations.map { [ _1.path, _1.reason ] }
      assert_nil result.sha
      assert_equal before, repo.head("wip/REC-1")
      assert_not dir.join("designs/jobs.html").exist?
      assert_not dir.join("notes.md").exist?
    end
  end

  test "a library passage added to a tracked file is refused and the edit is undone" do
    with_design_remote do |repo, _|
      seed_master(repo, { "README.md" => "hi\n", "designs/jobs.html" => "<p>jobs</p>\n" })
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      File.write(dir.join("designs/jobs.html"), "<p>jobs</p>\n<!-- #{LIBRARY} -->\n")
      result = committer(repo, forbidden_texts: [ LIBRARY ]).commit!(dir, message: "Turn 1")
      assert_equal [ "contains a passage from the Flosis library" ], result.violations.map(&:reason)
      assert_equal "<p>jobs</p>\n", File.read(dir.join("designs/jobs.html"))
      assert_equal before, repo.head("wip/REC-1")
    end
  end

  test "a stored credential is refused, left out of the history and out of the worktree" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("designs").tap(&:mkpath).join("index.html"), "<script>const key = 'ghp_SECRET123'</script>")
      result = committer(repo, secrets: [ "ghp_SECRET123" ]).commit!(dir, message: "Turn 1")
      assert_equal [ "contains a stored credential" ], result.violations.map(&:reason)
      assert_not_includes result.violations.inspect, "ghp_SECRET123"
      assert_not dir.join("designs/index.html").exist?
    end
  end

  # Ruling R13.
  test "a git configuration file inside an allowed folder is refused and removed" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      FileUtils.mkdir_p(dir.join("designs"))
      File.write(dir.join("designs/.gitattributes"), "*.html filter=stash\n")
      File.write(dir.join("designs/jobs.html"), "<p>jobs</p>")
      result = committer(repo).commit!(dir, message: "Turn 1")
      assert_equal [ "designs/.gitattributes" ], result.violations.map(&:path)
      assert_nil result.sha
      assert_not dir.join("designs/.gitattributes").exist?
    end
  end

  # Ruling P2-R3. Every page loads the runtime, and ensure_clone! refuses a
  # master without it: approved, one such commit would lock the project out
  # of its own design repo.
  test "a turn that deletes or renames the runtime is refused, and the runtime is put back" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      runtime = dir.join(Designs::Repo::RUNTIME)
      [ -> { runtime.delete }, -> { File.rename(runtime, dir.join("runtime/flosis-old.js")) } ].each do |change|
        change.call
        File.write(dir.join("designs").tap(&:mkpath).join("index.html"), "<h1>Hi</h1>")
        result = committer(repo).commit!(dir, message: "Turn 1")
        # runtime/ is Flosis's: a turn may not touch it at all, deleting least of all.
        assert_includes result.violations.map { [ _1.path, _1.reason ] }, [ "runtime/flosis.js", "would delete the design runtime" ]
        assert_nil result.sha
        assert_equal before, repo.head("wip/REC-1")
        assert_equal "// the runtime\n", runtime.read
        assert_not dir.join("designs/index.html").exist?
        assert_not dir.join("runtime/flosis-old.js").exist?
      end
    end
  end

  # Workshop Designs v2: runtime/ is Flosis's own, so a turn may not edit it either.
  test "a turn may not edit the runtime" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      File.write(dir.join(Designs::Repo::RUNTIME), "// the runtime, extended\n")
      result = committer(repo).commit!(dir, message: "Turn 1")
      assert_equal [ [ "runtime/flosis.js", "is outside the design repo's allowed folders" ] ],
                   result.violations.map { [ _1.path, _1.reason ] }
      assert_equal before, repo.head("wip/REC-1")
    end
  end

  # Ruling P2-R30: the one wording of a refusal, for a turn and for the repo's
  # first commit alike.
  test "a refusal names each refused path with its rule, and never the text" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("designs").tap(&:mkpath).join("index.html"), "<p>ghp_SECRET123</p>")
      File.write(dir.join("notes.md"), "scratch")
      result = committer(repo, secrets: [ "ghp_SECRET123" ]).commit!(dir, message: "Turn 1")
      assert_equal "designs/index.html contains a stored credential; notes.md is outside the design repo's allowed folders",
                   result.refusal
    end
  end

  test "a turn that changed nothing commits nothing and is not a refusal" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      before = repo.head("wip/REC-1")
      result = committer(repo).commit!(dir, message: "Turn 1")
      assert result.ok?
      assert_nil result.sha
      assert_equal before, repo.head("wip/REC-1")
    end
  end

  test "inspecting a committer does not print the credentials or library passages its guard holds" do
    guard = Designs::LeakGuard.new(forbidden_texts: [ LIBRARY ], secrets: [ "ghp_SECRET123" ])
    shown = Designs::Committer.new(Designs::Repo.new(projects(:jira_project), remote_url: "unused"), guard).inspect

    assert_includes shown, "Designs::LeakGuard"
    assert_not_includes shown, "ghp_SECRET123"
    assert_not_includes shown.downcase, "grotesk"
  end

  test "a clean turn is committed with its message, the repo lock held from staging to commit" do
    with_design_remote do |repo, _|
      seed_master(repo)
      dir = repo.worktree!("wip/REC-1")
      File.write(dir.join("designs").tap(&:mkpath).join("index.html"), "<h1>Hi</h1>")

      # flock locks per open file description: a second open in this very
      # process cannot take a lock the repo holds, and says so at once.
      lock_path = repo.root.dirname.join("design-repo.lock")
      lock_free = -> { File.open(lock_path) { |other| other.flock(File::LOCK_EX | File::LOCK_NB) != false } }
      free_at = {}
      guard = Designs::LeakGuard.new
      guard.define_singleton_method(:check) { |changes| free_at[:check] = lock_free.call; super(changes) }
      repo.define_singleton_method(:commit!) { |checkout, message:| free_at[:commit] = lock_free.call; super(checkout, message: message) }

      result = Designs::Committer.new(repo, guard).commit!(dir, message: "Turn 1")

      assert result.ok?
      assert_equal({ check: false, commit: false }, free_at)
      assert lock_free.call, "the lock is released when the commit is done"
      assert_equal "Turn 1", GitRunner.run!("log", "-1", "--format=%s", chdir: dir).strip
    end
  end
end
