require "test_helper"
require "json"
require "fileutils"

class ProjectMcpConfigTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @project = projects(:jira_project)
    @project.update!(workspace_dir: @dir, github_repo: "acme/app", github_token: "ght",
                     jira_site: "acme.atlassian.net", jira_email: "e@x.com", jira_api_token: "jt",
                     external_reference: "DEV")
  end
  teardown { FileUtils.remove_entry(@dir) if File.exist?(@dir) }

  test "writes .mcp.json with github and jira servers keyed exactly" do
    path = ProjectMcpConfig.write!(@project)
    assert_equal File.join(@dir, ".mcp.json"), path
    json = JSON.parse(File.read(path))
    servers = json["mcpServers"]
    assert servers.key?("github"), "server key must be exactly 'github'"
    assert servers.key?("jira"), "server key must be exactly 'jira'"
    assert_equal "npx", servers["github"]["command"]
    assert_equal "ght", servers["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]
    assert_equal "mcp-atlassian", servers["jira"]["command"]
    assert_equal "https://acme.atlassian.net", servers["jira"]["env"]["JIRA_URL"]
    assert_equal "jt", servers["jira"]["env"]["JIRA_API_TOKEN"]
  end

  test "file is chmod 600 and dir 700" do
    path = ProjectMcpConfig.write!(@project)
    assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    assert_equal "700", format("%o", File.stat(@dir).mode & 0o777)
  end

  test "omits a server whose creds do not resolve" do
    @project.update!(github_repo: nil, github_token: nil)
    @project.workspace.update!(github_repo: nil, github_token: nil)
    path = ProjectMcpConfig.write!(@project)
    json = JSON.parse(File.read(path))
    assert_not json["mcpServers"].key?("github"), "github omitted when unconfigured"
    assert json["mcpServers"].key?("jira")
  end

  test "sets mcp_synced_at" do
    assert_nil @project.mcp_synced_at
    ProjectMcpConfig.write!(@project)
    assert_not_nil @project.reload.mcp_synced_at
  end

  test "self-heals a deleted file" do
    path = ProjectMcpConfig.write!(@project)
    File.delete(path)
    ProjectMcpConfig.write!(@project)
    assert File.exist?(path)
  end

  test "path_for returns the mcp.json path" do
    assert_equal File.join(@dir, ".mcp.json"), ProjectMcpConfig.path_for(@project)
  end
end
