require "json"
require "fileutils"

# Writes a per-project .mcp.json wiring the `github` and `jira` stdio MCP
# servers to that project's resolved credentials. DB is the source of truth;
# call write! on integration save and again right before each automation run
# (self-heals a missing/stale file). Server keys MUST be exactly "github" /
# "jira" so tool names match ClaudeCliService::AUTOMATION_TOOLS.
class ProjectMcpConfig
  FILENAME = ".mcp.json".freeze
  # MCP server binaries. Absolute paths avoid depending on the Solid Queue job's
  # PATH (which may not include ~/.local/bin or the node bin). Override via ENV
  # on the server; defaults are the bare commands for local/dev.
  JIRA_MCP_COMMAND = ENV.fetch("JIRA_MCP_COMMAND", "mcp-atlassian").freeze
  NPX_COMMAND = ENV.fetch("GITHUB_MCP_NPX", "npx").freeze

  def self.path_for(project)
    File.join(project.workspace_dir, FILENAME)
  end

  def self.write!(project)
    new(project).write!
  end

  def initialize(project)
    @project = project
    @creds = ProjectCredentials.new(project)
  end

  def write!
    dir = @project.workspace_dir
    raise ArgumentError, "project has no workspace_dir" if dir.blank?

    FileUtils.mkdir_p(dir)
    File.chmod(0o700, dir)

    path = File.join(dir, FILENAME)
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(config_hash))
    File.chmod(0o600, tmp)
    File.rename(tmp, path)

    @project.update_column(:mcp_synced_at, Time.current)
    path
  end

  private

  def config_hash
    servers = {}
    servers["github"] = github_server if @creds.github_configured?
    servers["jira"] = jira_server if @creds.jira_configured?
    { "mcpServers" => servers }
  end

  def github_server
    {
      "type" => "stdio",
      "command" => NPX_COMMAND,
      "args" => ["-y", "@modelcontextprotocol/server-github"],
      "env" => { "GITHUB_PERSONAL_ACCESS_TOKEN" => @creds.github_token }
    }
  end

  def jira_server
    {
      "type" => "stdio",
      "command" => JIRA_MCP_COMMAND,
      "env" => {
        "JIRA_URL" => "https://#{@creds.jira_site}",
        "JIRA_USERNAME" => @creds.jira_email,
        "JIRA_API_TOKEN" => @creds.jira_api_token
      }
    }
  end
end
