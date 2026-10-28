require "test_helper"

class GithubClientForProjectTest < ActiveSupport::TestCase
  test "for_project builds a configured client from the project's own creds" do
    project = projects(:jira_project)
    project.update!(github_repo: "acme/own", github_token: "pt")

    assert GithubClient.for_project(project).configured?
  end

  # Falling back to the workspace would review one client's repo with another
  # client's token.
  test "for_project ignores the workspace's creds" do
    projects(:jira_project).workspace.update!(github_repo: "ws/repo", github_token: "ws_token")
    project = projects(:jira_project)
    project.update!(github_repo: nil, github_token: nil)

    assert_not GithubClient.for_project(project).configured?
  end

  test "for_project is not configured when nothing resolves" do
    project = projects(:jira_project)
    project.update!(github_repo: nil, github_token: nil)

    assert_not GithubClient.for_project(project).configured?
  end
end
