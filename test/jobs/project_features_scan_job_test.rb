require "test_helper"

class ProjectFeaturesScanJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = @workspace.projects.create!(name: "FS", color: "#555555",
      external_type: "jira", external_reference: "FS")
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
    def job.pull_latest!; true; end
    job
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
    def job.pull_latest!; false; end
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
end
