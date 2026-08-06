require "test_helper"

class ProjectCredentialsColumnsTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "new credential columns exist" do
    %w[github_repo github_token jira_site jira_email jira_api_token
       workspace_dir repo_checkout_status repo_checkout_error mcp_synced_at].each do |col|
      assert_includes Project.column_names, col, "missing column #{col}"
    end
  end

  test "github_token and jira_api_token are encrypted at rest" do
    @project.update!(github_token: "ghp_secret", jira_api_token: "jira_secret")
    raw = Project.connection.select_one(
      "SELECT github_token, jira_api_token FROM projects WHERE id = #{@project.id}"
    )
    assert_not_equal "ghp_secret", raw["github_token"], "github_token must be encrypted at rest"
    assert_not_equal "jira_secret", raw["jira_api_token"], "jira_api_token must be encrypted at rest"
    assert_equal "ghp_secret", @project.reload.github_token
    assert_equal "jira_secret", @project.reload.jira_api_token
  end
end
