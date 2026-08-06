require "test_helper"
require "fileutils"

class ProjectRepoCheckoutJobTest < ActiveJob::TestCase
  setup do
    @tmp = Dir.mktmpdir
    @project = projects(:jira_project)
    # Point this project's dir at an isolated tmp folder so the clone branch
    # doesn't create real dirs under ~/work/clients.
    @project.update!(workspace_dir: File.join(@tmp, "checkout"), github_repo: nil, github_token: nil)
    @project.workspace.update!(github_repo: "acme/app", github_token: "ght")
  end
  teardown { FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp) }

  # Capture git commands instead of hitting the network.
  def with_git_capture
    calls = []
    ProjectRepoCheckoutJob.stub_git = ->(cmd, chdir:) { calls << { cmd: cmd, chdir: chdir }; true }
    yield calls
  ensure
    ProjectRepoCheckoutJob.stub_git = nil
  end

  test "clones when no checkout exists and marks ready" do
    with_git_capture do |calls|
      ProjectRepoCheckoutJob.perform_now(@project.id)
      assert calls.any? { |c| c[:cmd].include?("clone") }, "should clone"
    end
    assert_equal "ready", @project.reload.repo_checkout_status
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

  test "does nothing when github not configured" do
    @project.workspace.update!(github_repo: nil, github_token: nil)
    assert_nothing_raised { ProjectRepoCheckoutJob.perform_now(@project.id) }
  end
end
