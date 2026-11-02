require "test_helper"

class GithubClientForProjectTest < ActiveSupport::TestCase
  test "for_project builds a configured client from the project's own creds" do
    project = projects(:jira_project)
    project.update!(github_repo: "acme/own", github_token: "pt")

    assert GithubClient.for_project(project).configured?
  end

  # Falling back to the workspace would review one client's repo with another
  # client's token. There is now nothing to fall back TO — the workspace cannot
  # hold credentials at all — which is a stronger guarantee than the resolver
  # choosing not to read them, so that is what this pins down.
  test "a workspace cannot hold credentials for a project to borrow" do
    assert_not Workspace.column_names.include?("github_token")
    assert_not Workspace.column_names.include?("github_repo")
    assert_not GithubClient.respond_to?(:for), "a workspace-wide client is back"
  end

  test "for_project is not configured when the project itself has nothing" do
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
