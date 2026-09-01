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

  def with_env(vars)
    previous = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "writes .mcp.json with github and jira servers keyed exactly" do
    path = ProjectMcpConfig.write!(@project)
    assert_equal File.join(@dir, ".mcp.json"), path
    json = JSON.parse(File.read(path))
    servers = json["mcpServers"]
    assert servers.key?("github"), "server key must be exactly 'github'"
    assert servers.key?("jira"), "server key must be exactly 'jira'"
    assert_equal "github-mcp-server", servers["github"]["command"]
    assert_equal [ "stdio", "--read-only" ], servers["github"]["args"]
    assert_equal "ght", servers["github"]["env"]["GITHUB_PERSONAL_ACCESS_TOKEN"]
    assert_equal "mcp-atlassian", servers["jira"]["command"]
    assert_equal "https://acme.atlassian.net", servers["jira"]["env"]["JIRA_URL"]
    assert_equal "jt", servers["jira"]["env"]["JIRA_API_TOKEN"]
  end

  # The deprecated @modelcontextprotocol/server-github started denying
  # list_pull_requests / list_commits with a token that returns 200 on the same
  # REST endpoints. Nothing may point back at it.
  test "wires GitHub's own server, never the deprecated npx reference one" do
    json = JSON.parse(File.read(ProjectMcpConfig.write!(@project)))
    github = json["mcpServers"]["github"]

    assert_no_match(/modelcontextprotocol\/server-github/, github.to_json)
    assert_no_match(/npx/, github["command"])
    assert_equal "stdio", github["type"]
  end

  # Automations read from GitHub and write to Jira; the server should not even
  # offer merge_pull_request or delete_file.
  test "the GitHub server runs read-only" do
    json = JSON.parse(File.read(ProjectMcpConfig.write!(@project)))

    assert_includes json["mcpServers"]["github"]["args"], "--read-only"
  end

  # The i18n automation has to POST to Lit. Rather than granting it Bash — which
  # would put SECRET_KEY_BASE and the database password within reach of a prompt
  # — it gets our own two-call server.
  test "wires the Lit server when a key is configured, with the key in its env" do
    with_env("LIT_AI_API_KEY" => "lit-key", "LIT_API_BASE" => "https://lit.test") do
      json = JSON.parse(File.read(ProjectMcpConfig.write!(@project)))
      lit = json["mcpServers"]["lit"]

      assert_not_nil lit, "server key must be exactly 'lit' so tool names match AUTOMATION_TOOLS"
      assert_equal "stdio", lit["type"]
      assert_equal [ Rails.root.join("lib/mcp/lit_server.rb").to_s ], lit["args"]
      assert_equal "lit-key", lit["env"]["LIT_AI_API_KEY"]
      assert_equal "https://lit.test", lit["env"]["LIT_API_BASE"]
      assert File.exist?(lit["args"].first), "the script the config points at must exist"
    end
  end

  test "omits the Lit server when no key is configured" do
    with_env("LIT_AI_API_KEY" => nil) do
      json = JSON.parse(File.read(ProjectMcpConfig.write!(@project)))

      assert_not json["mcpServers"].key?("lit")
    end
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
