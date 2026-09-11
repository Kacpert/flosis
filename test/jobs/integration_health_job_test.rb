require "test_helper"

# A chip that goes green on "somebody filled the field in" is worse than no
# chip. A Figma token expired without a sound and the AI was the one to tell a
# client it couldn't open the design — these cover the job that keeps asking.
class IntegrationHealthJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_repo: "acme/widgets", github_token: "t", figma_read_enabled: true)
    @project = projects(:jira_project)
    @project.update!(jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt")
  end

  def with_health(jira:, github:, figma:)
    jira_orig = JiraClient.instance_method(:health_check)
    github_orig = GithubClient.instance_method(:health_check)
    figma_orig = FigmaClient.instance_method(:health_check)
    JiraClient.define_method(:health_check) { jira }
    GithubClient.define_method(:health_check) { github }
    FigmaClient.define_method(:health_check) { figma }
    yield
  ensure
    JiraClient.define_method(:health_check, jira_orig)
    GithubClient.define_method(:health_check, github_orig)
    FigmaClient.define_method(:health_check, figma_orig)
  end

  test "records a healthy result for every integration" do
    with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: true }) do
      IntegrationHealthJob.perform_now
    end

    @workspace.reload
    assert @workspace.jira_status_ok
    assert @workspace.github_status_ok
    assert @workspace.figma_status_ok
    assert_not_nil @workspace.figma_status_checked_at
    assert_nil @workspace.figma_status_error
  end

  test "records the reason a token stopped working" do
    with_health(jira: { ok: true }, github: { ok: true },
                figma: { ok: false, error: "401 Unauthorized — Token has expired" }) do
      IntegrationHealthJob.perform_now
    end

    @workspace.reload
    assert_equal false, @workspace.figma_status_ok
    assert_equal "401 Unauthorized — Token has expired", @workspace.figma_status_error
    assert @workspace.jira_status_ok, "one broken integration doesn't taint the others"
  end

  test "skips Figma when the workspace never asked the AI to read it" do
    @workspace.update!(figma_read_enabled: false)

    with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: false, error: "boom" }) do
      IntegrationHealthJob.perform_now
    end

    assert_nil @workspace.reload.figma_status_checked_at, "nothing to report on an integration nobody uses"
  end

  test "a workspace that raises does not stop the others being checked" do
    other = workspaces(:two)
    other.update!(github_repo: "acme/other", github_token: "t")

    # Make one workspace explode inside its check. The id is captured here:
    # inside define_singleton_method `self` is the class, not the test.
    exploding_id = @workspace.id
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) do |workspace|
      raise "boom" if workspace.id == exploding_id
      orig.call(workspace)
    end

    begin
      with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: true }) do
        assert_nothing_raised { IntegrationHealthJob.perform_now }
      end
    ensure
      GithubClient.define_singleton_method(:for, orig)
    end

    assert other.reload.github_status_ok, "the second workspace was still checked"
  end
end
