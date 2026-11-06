require "test_helper"

class ProjectFeaturesScanJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = @workspace.projects.create!(name: "FS", color: "#555555",
      external_type: "jira", external_reference: "FS")
    checkout!(@project)
  end

  def with_ai(response)
    orig = ClaudeCliService.instance_method(:start_session)
    ClaudeCliService.define_method(:start_session) { |**_kw| { session_id: "s", response: response } }
    yield
  ensure
    ClaudeCliService.define_method(:start_session, orig)
  end

  def job_without_pull
    job = ProjectFeaturesScanJob.new
    def job.pull_latest!(*, **); true; end
    job
  end

  # Captures what GitRunner is asked to run, or raises what GitHub would.
  def with_git(error: nil)
    calls = []
    original = GitRunner.method(:run!)
    GitRunner.define_singleton_method(:run!) do |*args, chdir:, token: nil|
      calls << [ args, chdir.to_s, token ]
      raise GitRunner::Error, error if error

      ""
    end
    yield calls
  ensure
    GitRunner.define_singleton_method(:run!, original)
  end

  test "a good scan stores the summary" do
    with_ai("This app does X, Y, Z. Architecture: Rails monolith with Solid Queue and Turbo.") do
      job_without_pull.perform
    end
    assert_match "Architecture", @project.reload.features_summary
    assert_not_nil @project.features_summary_updated_at
  end

  test "an auth-error response preserves the previous summary" do
    @project.update!(features_summary: "PREVIOUS", features_summary_updated_at: 1.day.ago)
    with_ai("API Error: 401 Invalid authentication credentials") do
      job_without_pull.perform
    end
    assert_equal "PREVIOUS", @project.reload.features_summary
  end

  test "a failed git pull skips scanning entirely" do
    @project.update!(features_summary: "PREVIOUS")
    job = ProjectFeaturesScanJob.new
    def job.pull_latest!(*, **); false; end
    with_ai("new summary that is long enough to pass the length gate easily here") do
      job.perform
    end
    assert_equal "PREVIOUS", @project.reload.features_summary
  end

  test "only scans workshop-enabled workspaces' jira projects" do
    @workspace.update!(workshop_enabled: false)
    with_ai("a sufficiently long summary about features and architecture goes here") do
      job_without_pull.perform
    end
    assert_nil @project.reload.features_summary
  end

  test "single-project mode scans only the given project (the manual Refresh button)" do
    other = @workspace.projects.create!(name: "Other", color: "#666666",
      external_type: "jira", external_reference: "OTH")
    with_ai("A long enough plain-language feature list for the requested project only.") do
      job_without_pull.perform(@project.id)
    end

    assert_match "feature list", @project.reload.features_summary
    assert_nil other.reload.features_summary, "must not scan other projects in single-project mode"
  end

  # The checkout's remote is the plain https://github.com/<repo>.git, never
  # with a token in it (ProjectRepoCheckoutJob): a pull that does not hand
  # the project's token over fails on a private repository, every night.
  test "the pull reaches GitHub with the project's own token" do
    @project.update!(github_repo: "https://github.com/acme/app.git", github_token: "ght")
    checkout!(@project)
    with_git do |calls|
      with_ai("This app does X, Y, Z. Architecture: Rails monolith with Solid Queue and Turbo.") do
        ProjectFeaturesScanJob.new.perform
      end
      assert_equal [ [ %w[pull --ff-only], @project.ai_codebase_path, "ght" ] ], calls
    end
    assert_match "Architecture", @project.reload.features_summary
  end

  test "a pull GitHub refuses keeps the previous summary" do
    @project.update!(github_token: "ght", features_summary: "PREVIOUS")
    with_git(error: "git pull failed: fatal: could not read Username for 'https://github.com'") do
      with_ai("new summary that is long enough to pass the length gate easily here") do
        ProjectFeaturesScanJob.new.perform
      end
    end
    assert_equal "PREVIOUS", @project.reload.features_summary
  end
end
