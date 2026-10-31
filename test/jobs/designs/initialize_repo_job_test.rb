require "test_helper"

class Designs::InitializeRepoJobTest < ActiveJob::TestCase
  include DesignRepoTestHelper

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  test "an empty repo gets master from the template, pushed and published" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      project = repo.project.reload
      assert_equal "ready", project.design_repo_status
      assert remote_branch_sha(remote, "master")
      assert File.exist?(File.join(@preview_root, project.design_preview_token, "master", "runtime", "flosis.js"))
    end
  end

  test "an initialized repo gets no second commit" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      first = remote_branch_sha(remote, "master")
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert_equal first, remote_branch_sha(remote, "master")
      assert_equal "ready", repo.project.reload.design_repo_status
    end
  end

  test "records a push failure without the token" do
    with_design_remote do |repo, remote|
      FileUtils.chmod_R("a-w", remote)
      begin
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      ensure
        FileUtils.chmod_R("u+w", remote)
      end
      project = repo.project.reload
      assert_equal "error", project.design_repo_status
      assert project.design_repo_error.present?
      assert_not_includes project.design_repo_error, "design-token"
    end
  end

  test "does nothing for a project with Designs off" do
    with_design_remote do |repo, remote|
      repo.project.update!(designs_enabled: false)
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert_nil repo.project.reload.design_repo_status
      assert_nil remote_branch_sha(remote, "master")
    end
  end

  # Beyond the brief.

  test "does nothing until the design repo and its token are both set" do
    with_design_remote do |repo, remote|
      [ { design_repo_token: nil }, { design_repo: nil } ].each do |gap|
        repo.project.update!(gap)
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
        assert_nil repo.project.reload.design_repo_status, gap.inspect
        assert_not repo.root.exist?, gap.inspect
        repo.project.update!(design_repo: "acme/designs", design_repo_token: "design-token")
      end
    end
  end

  test "does nothing for a project that no longer exists" do
    assert_nothing_raised { Designs::InitializeRepoJob.perform_now(0) }
  end

  test "the project shows as initializing while the repo is started, under the repo's lock" do
    with_design_remote do |repo, remote|
      lock = File.join(repo.project.designs_dir, "design-repo.lock")
      seen = nil
      observer = lambda do |project|
        seen = [ Project.find(project.id).design_repo_status,
                 File.open(lock) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) } ]
      end
      watching_render(observer) do
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      end
      assert_equal [ "initializing", false ], seen
    end
  end

  test "the first commit is Flosis's, named for what it does, and holds the template" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert_equal [ "Start the design repo", "Flosis <designs@flosis.com>" ],
                   GitRunner.run!("log", "-1", "--format=%s%n%an <%ae>", "master", chdir: remote).lines(chomp: true)
      assert_equal 1, GitRunner.run!("rev-list", "--count", "master", chdir: remote).to_i
      files = GitRunner.run!("ls-tree", "-r", "--name-only", "master", chdir: remote).lines(chomp: true)
      assert_includes files, "README.md"
      assert_includes files, "runtime/flosis.js"
    end
  end

  test "an initialized repo is published again, from the master it already has" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      slot = File.join(@preview_root, repo.project.reload.design_preview_token, "master")
      FileUtils.rm_rf(slot)
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert File.exist?(File.join(slot, "README.md"))
    end
  end

  # The template is only where a repo starts: once it has been set up, the job
  # must not put the template back over the design system.
  test "an initialized repo keeps what was committed to it since: the job only publishes" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      commit_files(repo, repo.root, { "design_system/theme.css" => "a theme the setup run wrote\n" })
      repo.push!("master")
      set_up = remote_branch_sha(remote, "master")

      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      assert_equal set_up, remote_branch_sha(remote, "master")
      theme = File.join(@preview_root, repo.project.reload.design_preview_token, "master", "design_system", "theme.css")
      assert_equal "a theme the setup run wrote\n", File.read(theme)
    end
  end

  # The guard is shown the project's own credentials, all of them. The project's
  # name goes into the README, so naming it after a credential is what makes
  # the first commit carry one.
  test "a first commit that carries any credential the project stores is refused, and never repeats it" do
    with_design_remote do |repo, remote|
      project = repo.project
      %i[design_repo_token github_token anthropic_api_key jira_api_token figma_token].each do |column|
        kept = project.public_send(column)
        secret = "stored-#{column}-value"
        project.update!(column => secret, name: "Acme #{secret}")
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(project.id) }
        project.reload
        assert_equal "error", project.design_repo_status, column.to_s
        assert_includes project.design_repo_error, "README.md contains a stored credential", column.to_s
        assert_not_includes project.design_repo_error, secret, column.to_s
        assert_nil remote_branch_sha(remote, "master"), column.to_s
        project.update!(column => kept)
      end
    end
  end

  test "a refused first commit leaves the clone empty, and the next run starts from the template again" do
    with_design_remote do |repo, remote|
      project = repo.project
      project.update!(github_token: "stored-github-token", name: "Acme stored-github-token")
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(project.id) }
      assert_equal "error", project.reload.design_repo_status
      assert_equal [ ".git" ], Dir.children(repo.root)
      assert_empty GitRunner.run!("status", "--porcelain", chdir: repo.root)
      assert_nil repo.head("master")

      project.update!(name: "Acme")
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(project.id) }
      assert_equal "ready", project.reload.design_repo_status
      assert remote_branch_sha(remote, "master")
    end
  end

  # The first run committed before its push failed. The second has nothing new
  # to commit, and must still push what the first left.
  test "a push that failed is retried from the commit it left, without a second one" do
    with_design_remote do |repo, remote|
      FileUtils.chmod_R("a-w", remote)
      begin
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      ensure
        FileUtils.chmod_R("u+w", remote)
      end
      assert_equal "error", repo.project.reload.design_repo_status
      assert_nil remote_branch_sha(remote, "master")

      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      project = repo.project.reload
      assert_equal "ready", project.design_repo_status
      assert_nil project.design_repo_error
      assert_equal 1, GitRunner.run!("rev-list", "--count", "master", chdir: remote).to_i
    end
  end

  # GitHub's "Add a README" creates main. The refusal says why, and emptying the
  # repo, as it advises, must be enough: the next run starts from the template
  # rather than on top of the old main.
  test "a repo that already has a branch is refused with the reason, and started once it is emptied" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n" })
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      project = repo.project.reload
      assert_equal "error", project.design_repo_status
      assert_equal "The design repo must be empty — it already has: main. Create an empty repository, or remove them.",
                   project.design_repo_error
      assert_nil remote_branch_sha(remote, "master")

      system("git", "-C", remote, "update-ref", "-d", "refs/heads/main", exception: true)
      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      project.reload
      assert_equal "ready", project.design_repo_status
      assert_nil project.design_repo_error
      master = remote_branch_sha(remote, "master")
      assert master
      assert_equal [ master ], GitRunner.run!("rev-list", "--parents", "-n", "1", master, chdir: remote).split,
                   "master starts from the template, not on top of the old main"
      assert File.exist?(File.join(@preview_root, project.design_preview_token, "master", "README.md"))
    end
  end

  # The error is logged as well as stored; neither may carry the token.
  test "a failure is logged with its project and reason, and without the token" do
    with_design_remote do |repo, remote|
      log = StringIO.new
      logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)
      FileUtils.chmod_R("a-w", remote)
      begin
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      ensure
        FileUtils.chmod_R("u+w", remote)
        Rails.logger = logger
      end
      assert_includes log.string, "[Designs::InitializeRepoJob] project #{repo.project.id}: GitRunner::Error: git push failed"
      assert_not_includes log.string, "design-token"
    end
  end

  # A message that is not valid UTF-8 (a file name in git's output) cannot be
  # written to the column, and the failure to record the error would leave the
  # project on "initializing" for good.
  test "an error whose message is not valid UTF-8 is still recorded" do
    with_design_remote do |repo, remote|
      watching_render(->(_project) { raise "git said caf\xE9" }) do
        with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      end
      project = repo.project.reload
      assert_equal "error", project.design_repo_status
      assert_equal "git said caf�", project.design_repo_error
    end
  end

  test "at most the first 500 characters of an error are stored" do
    with_design_remote do |repo, remote|
      system("git", "-C", remote, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)
      push_from_elsewhere(remote, "main", { "README.md" => "# acme\n" })
      main = remote_branch_sha(remote, "main")
      refs = (1..80).map { |n| "create refs/heads/branch-number-#{n} #{main}\n" }.join
      _, status = Open3.capture2e("git", "-C", remote, "update-ref", "--stdin", stdin_data: refs)
      assert status.success?

      with_remote_url(remote) { Designs::InitializeRepoJob.perform_now(repo.project.id) }
      error = repo.project.reload.design_repo_error
      assert_equal 500, error.length
      assert error.start_with?("The design repo must be empty — it already has: branch-number-1, ")
    end
  end

  private

  # Runs the block with the observer called, with the project, each time the
  # template is about to be rendered; the template is rendered as usual.
  def watching_render(observer)
    original = Designs::Template.method(:render_into)
    Designs::Template.define_singleton_method(:render_into) do |dir, project:|
      observer.call(project)
      original.call(dir, project: project)
    end
    yield
  ensure
    Designs::Template.define_singleton_method(:render_into, original)
  end
end
