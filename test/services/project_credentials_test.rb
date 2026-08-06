require "test_helper"

class ProjectCredentialsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(github_repo: "ws/repo", github_token: "ws_token")
    @project = projects(:jira_project)
    @project.update!(external_reference: "DEV")
  end

  test "github falls back to workspace when project is blank" do
    creds = ProjectCredentials.new(@project)
    assert_equal "ws/repo", creds.github_repo
    assert_equal "ws_token", creds.github_token
  end

  test "project github overrides workspace" do
    @project.update!(github_repo: "proj/repo", github_token: "proj_token")
    creds = ProjectCredentials.new(@project)
    assert_equal "proj/repo", creds.github_repo
    assert_equal "proj_token", creds.github_token
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

  test "jira_key comes from external_reference" do
    assert_equal "DEV", ProjectCredentials.new(@project).jira_key
  end

  test "configured predicates" do
    @project.update!(github_repo: "p/r", github_token: "t",
                     jira_site: "s", jira_email: "e", jira_api_token: "jt")
    creds = ProjectCredentials.new(@project)
    assert creds.github_configured?
    assert creds.jira_configured?
  end

  test "not configured when creds missing everywhere" do
    @workspace.update!(github_repo: nil, github_token: nil)
    %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].each { |k| ENV.delete(k) }
    creds = ProjectCredentials.new(@project)
    assert_not creds.github_configured?
    assert_not creds.jira_configured?
  end
end
