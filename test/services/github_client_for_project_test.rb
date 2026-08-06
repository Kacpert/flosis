require "test_helper"

class GithubClientForProjectTest < ActiveSupport::TestCase
  test "for_project builds a configured client from resolved creds" do
    workspace = workspaces(:one)
    workspace.update!(github_repo: "ws/repo", github_token: "ws_token")
    project = projects(:jira_project)
    client = GithubClient.for_project(project)
    assert client.configured?, "should be configured via workspace fallback"
  end

  test "for_project is not configured when nothing resolves" do
    workspace = workspaces(:one)
    workspace.update!(github_repo: nil, github_token: nil)
    project = projects(:jira_project)
    project.update!(github_repo: nil, github_token: nil)
    assert_not GithubClient.for_project(project).configured?
  end
end
