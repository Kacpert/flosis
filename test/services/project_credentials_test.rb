require "test_helper"

# One place answers "what credentials does this project use". The workspace
# fallback is gone: a second client's keys have nowhere to fall back TO, and a
# silent fallback to the first client's token is worse than a blank field.
class ProjectCredentialsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @project = projects(:jira_project)
    @project.update!(external_reference: "DEV")
  end

  test "reads the project's own keys" do
    @project.update!(github_repo: "acme/own", github_token: "pt", figma_token: "ft",
                     figma_read_enabled: true)
    creds = ProjectCredentials.new(@project)

    assert_equal "acme/own", creds.github_repo
    assert_equal "pt", creds.github_token
    assert_equal "ft", creds.figma_token
    assert creds.figma_configured?
  end

  test "does not borrow the workspace's key" do
    @project.update!(github_repo: nil, github_token: nil)
    @workspace.update!(github_repo: "ws/repo", github_token: "workspace-token")
    creds = ProjectCredentials.new(@project)

    assert_nil creds.github_token
    assert_nil creds.github_repo
  end

  test "jira falls back to ENV when project is blank" do
    ENV["JIRA_DOMAIN"] = "env.atlassian.net"
    ENV["JIRA_EMAIL"] = "env@example.com"
    ENV["JIRA_API_TOKEN"] = "env_token"
    creds = ProjectCredentials.new(@project)
    assert_equal "env.atlassian.net", creds.jira_site
    assert_equal "env@example.com", creds.jira_email
    assert_equal "env_token", creds.jira_api_token
  ensure
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
  end

  test "project jira overrides ENV" do
    ENV["JIRA_DOMAIN"] = "env.atlassian.net"
    @project.update!(jira_site: "proj.atlassian.net", jira_email: "p@x.com", jira_api_token: "pt")
    creds = ProjectCredentials.new(@project)
    assert_equal "proj.atlassian.net", creds.jira_site
    assert_equal "p@x.com", creds.jira_email
    assert_equal "pt", creds.jira_api_token
  ensure
    ENV.delete("JIRA_DOMAIN")
  end

  # The CLI already runs off the machine's own key, so a project that never set
  # one keeps working exactly as it does today.
  test "the AI key falls back to the environment" do
    @project.update!(anthropic_api_key: nil)
    ENV["ANTHROPIC_API_KEY"] = "env-key"

    assert_equal "env-key", ProjectCredentials.new(@project).anthropic_api_key
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  test "the project's own AI key wins over the environment" do
    @project.update!(anthropic_api_key: "project-key")
    ENV["ANTHROPIC_API_KEY"] = "env-key"

    assert_equal "project-key", ProjectCredentials.new(@project).anthropic_api_key
  ensure
    ENV.delete("ANTHROPIC_API_KEY")
  end

  test "jira_key comes from external_reference" do
    assert_equal "DEV", ProjectCredentials.new(@project).jira_key
  end

  test "configured predicates" do
    @project.update!(github_repo: "p/r", github_token: "t",
                     jira_site: "s", jira_email: "e", jira_api_token: "jt",
                     figma_read_enabled: true, figma_token: "ft")
    creds = ProjectCredentials.new(@project)
    assert creds.github_configured?
    assert creds.jira_configured?
    assert creds.figma_configured?
  end

  # A token nobody asked the AI to use is not a working integration — the
  # Figma chip and the MCP server both hang off the toggle, not the key alone.
  test "figma is not configured while the project has not enabled reading" do
    @project.update!(figma_read_enabled: false, figma_token: "ft")

    assert_not ProjectCredentials.new(@project).figma_configured?
  end

  test "not configured when creds missing everywhere" do
    @project.update!(github_repo: nil, github_token: nil, figma_token: nil)
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
    creds = ProjectCredentials.new(@project)
    assert_not creds.github_configured?
    assert_not creds.jira_configured?
    assert_not creds.figma_configured?
  end
end
