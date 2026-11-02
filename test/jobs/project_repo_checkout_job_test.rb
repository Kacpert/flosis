require "test_helper"
require "fileutils"

class ProjectRepoCheckoutJobTest < ActiveJob::TestCase
  setup do
    @tmp = Dir.mktmpdir
    @project = projects(:jira_project)
    # Point this project's dir at an isolated tmp folder so the clone branch
    # doesn't create real dirs under ~/work/clients.
    @project.update!(workspace_dir: File.join(@tmp, "checkout"),
                     github_repo: "acme/app", github_token: "ght")
  end
  teardown { FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp) }

  # Capture git commands instead of hitting the network.
  def with_git_capture
    calls = []
    ProjectRepoCheckoutJob.stub_git = ->(args, chdir:, token: nil) { calls << { args: args, chdir: chdir, token: token }; true }
    yield calls
  ensure
    ProjectRepoCheckoutJob.stub_git = nil
  end

  test "clones when no checkout exists and marks ready" do
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert calls.any? { |c| c[:args].first == "clone" }, "should clone"
    end
    assert_equal "ready", @project.reload.repo_checkout_status
  end

  test "clones a URL that carries no token, and hands the token over separately" do
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      clone = calls.find { |c| c[:args].first == "clone" }
      assert_equal "https://github.com/acme/app.git", clone[:args][1]
      assert_equal "ght", clone[:token]
      assert calls.none? { |c| c[:args].join(" ").include?("ght") }
    end
  end

  # Checkouts made before this change hold the token in their remote URL.
  # Rewriting it before every pull is what cleans them up.
  test "an existing checkout gets a tokenless remote before it pulls" do
    FileUtils.mkdir_p(File.join(@project.repo_checkout_path, ".git"))
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert_equal [ %w[remote set-url origin https://github.com/acme/app.git], %w[pull --ff-only] ],
                   calls.map { |c| c[:args] }
    end
  end

  test "skips clone for legacy elvium" do
    @project.update_column(:workspace_dir, Project::ELVIUM_LEGACY_DIR)
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert_empty calls, "legacy elvium must not clone/pull"
    end
  end

  test "records error status when git fails" do
    ProjectRepoCheckoutJob.stub_git = ->(*, **) { raise "network exploded" }
    begin
      assert_nothing_raised { ProjectRepoCheckoutJob.perform_now(@project.id) }
    ensure
      ProjectRepoCheckoutJob.stub_git = nil
    end
    assert_equal "error", @project.reload.repo_checkout_status
    assert_match "network exploded", @project.repo_checkout_error.to_s
  end

  # repo_checkout_error is a varchar(255) on MySQL and git's own message can run
  # longer. Stored whole, it raised from inside the rescue and left the status
  # on "cloning".
  test "a long git error is stored clipped to the 255 characters its column holds" do
    message = "git clone failed: ".ljust(400, "x")
    ProjectRepoCheckoutJob.stub_git = ->(*, **) { raise GitRunner::Error, message }
    begin
      assert_nothing_raised { ProjectRepoCheckoutJob.perform_now(@project.id) }
    ensure
      ProjectRepoCheckoutJob.stub_git = nil
    end
    @project.reload
    assert_equal "error", @project.repo_checkout_status
    assert_equal 255, @project.repo_checkout_error.length
    assert_equal message.first(255), @project.repo_checkout_error
  end

  # Only the project's own credentials count: a checkout cloned with another
  # project's token is the wrong repo, so a blank field means "do nothing".
  test "does nothing when the project has no github credentials of its own" do
    @project.update!(github_repo: nil, github_token: nil)

    with_git_capture do |calls|
      assert_nothing_raised { ProjectRepoCheckoutJob.perform_now(@project.id) }
      assert_empty calls
    end
  end
end
