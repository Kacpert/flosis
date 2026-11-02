require "test_helper"

# A chip that goes green on "somebody filled the field in" is worse than no
# chip. A Figma token expired without a sound and the AI was the one to tell a
# client it couldn't open the design — these cover the job that keeps asking.
class IntegrationHealthJobTest < ActiveJob::TestCase
  setup do
    @project = projects(:jira_project)
    @project.update!(github_repo: "acme/widgets", github_token: "t",
                     figma_read_enabled: true, figma_token: "ft",
                     jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt")
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

    @project.reload
    assert @project.jira_status_ok
    assert @project.github_status_ok
    assert @project.figma_status_ok
    assert_not_nil @project.figma_status_checked_at
    assert_nil @project.figma_status_error
  end

  test "records the reason a token stopped working" do
    with_health(jira: { ok: true }, github: { ok: true },
                figma: { ok: false, error: "401 Unauthorized — Token has expired" }) do
      IntegrationHealthJob.perform_now
    end

    @project.reload
    assert_equal false, @project.figma_status_ok
    assert_equal "401 Unauthorized — Token has expired", @project.figma_status_error
    assert @project.jira_status_ok, "one broken integration doesn't taint the others"
  end

  test "skips Figma when the project never asked the AI to read it" do
    @project.update!(figma_read_enabled: false)

    with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: false, error: "boom" }) do
      IntegrationHealthJob.perform_now
    end

    assert_nil @project.reload.figma_status_checked_at, "nothing to report on an integration nobody uses"
  end

  # The Jira domain, login and token fall back to the environment, so every
  # project on the box answers jira_configured?. Stamping them all green claims
  # a working integration that belongs to somebody else's client.
  test "a project with no Jira of its own is not checked even with the environment set" do
    other = projects(:plain_project)
    assert_not other.jira_connected?

    ENV["JIRA_DOMAIN"] = "acme.atlassian.net"
    ENV["JIRA_EMAIL"] = "e@x.com"
    ENV["JIRA_API_TOKEN"] = "jt"

    with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: true }) do
      IntegrationHealthJob.perform_now
    end

    assert_nil other.reload.jira_status_checked_at, "a project with no Jira was reported as Jira-healthy"
    assert @project.reload.jira_status_ok, "the Jira-connected project is still checked"
  ensure
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
  end

  test "an archived project is left alone" do
    @project.update!(archived: true)

    with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: true }) do
      IntegrationHealthJob.perform_now
    end

    assert_nil @project.reload.jira_status_checked_at
  end

  test "a project that raises does not stop the others being checked" do
    other = projects(:plain_project)
    other.update!(github_repo: "acme/other", github_token: "t")

    # Make one project explode inside its check. The id is captured here:
    # inside define_singleton_method `self` is the class, not the test.
    exploding_id = @project.id
    orig = GithubClient.method(:for_project)
    GithubClient.define_singleton_method(:for_project) do |project|
      raise "boom" if project.id == exploding_id
      orig.call(project)
    end

    begin
      with_health(jira: { ok: true }, github: { ok: true }, figma: { ok: true }) do
        assert_nothing_raised { IntegrationHealthJob.perform_now }
      end
    ensure
      GithubClient.define_singleton_method(:for_project, orig)
    end

    assert other.reload.github_status_ok, "the second project was still checked"
  end
end
