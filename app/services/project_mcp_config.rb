require "json"
require "fileutils"
require "rbconfig"

# Writes a per-project .mcp.json wiring the `github`, `jira` and `figma` stdio
# MCP servers to that project's resolved credentials. DB is the source of truth;
# call write! on integration save and again right before each automation run
# (self-heals a missing/stale file). Server keys MUST be exactly "github" /
# "jira" / "figma" so tool names match ClaudeCliService::AUTOMATION_TOOLS.
class ProjectMcpConfig
  FILENAME = ".mcp.json".freeze
  # MCP server binaries. Absolute paths avoid depending on the Solid Queue job's
  # PATH (which may not include ~/.local/bin or the node bin). Override via ENV
  # on the server; defaults are the bare commands for local/dev.
  JIRA_MCP_COMMAND = ENV.fetch("JIRA_MCP_COMMAND", "mcp-atlassian").freeze
  # GitHub's own server (github/github-mcp-server). It replaced
  # @modelcontextprotocol/server-github, which npm now reports as deprecated
  # ("Package no longer supported", frozen at 2025.4.8) and whose
  # list_pull_requests / list_commits / search_issues started answering
  # "Permission Denied: Resource not accessible by personal access token" —
  # while the very same token returns 200 on those REST endpoints.
  GITHUB_MCP_COMMAND = ENV.fetch("GITHUB_MCP_COMMAND", "github-mcp-server").freeze
  # Our own narrow Lit server (lib/mcp/lit_server.rb). Resolved from Rails.root
  # rather than pinned in ENV, because write! runs before every automation run —
  # so a fresh release's path lands in the file automatically.
  LIT_MCP_SCRIPT = "lib/mcp/lit_server.rb".freeze

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
    servers["jira"] = jira_server if jira_configured?
    servers["figma"] = figma_server if @creds.figma_configured?
    servers["lit"] = lit_server if lit_configured?
    { "mcpServers" => servers }
  end

  # jira_connected? as well as jira_configured?: the domain, login and token
  # all fall back to the environment, which is set on the server, so a project
  # with no Jira of its own still answers "configured" — and would be handed a
  # server pointed at somebody else's Jira, which the model then reads because
  # the tool is there. IntegrationHealthJob#check_jira gates the same way.
  def jira_configured?
    @project.jira_connected? && @creds.jira_configured?
  end

  # Lit is ONE shared instance (Elvium's), keyed from the app's own
  # environment, and its tools write into it. Only the project that is that
  # app may have them: handing them to every project let another client's
  # automation post translations into Elvium. legacy_elvium? is this branch's
  # established "this project is the Elvium checkout" predicate; the eventual
  # answer is a per-project Lit toggle alongside the other integrations.
  def lit_configured?
    ENV["LIT_AI_API_KEY"].present? && @project.legacy_elvium?
  end

  # Two calls, no more: post translation suggestions and ask Lit to re-scan for
  # keys. The alternative was granting the automation Bash to curl the endpoint,
  # which would hand a prompt the whole environment this process runs with —
  # SECRET_KEY_BASE, the database password, every token. See lib/mcp/lit_server.rb.
  def lit_server
    {
      "type" => "stdio",
      "command" => RbConfig.ruby,
      "args" => [ Rails.root.join(LIT_MCP_SCRIPT).to_s ],
      "env" => {
        "LIT_AI_API_KEY" => ENV["LIT_AI_API_KEY"],
        "LIT_API_BASE" => ENV.fetch("LIT_API_BASE", "https://pre-prod.elvium.com")
      }
    }
  end

  # --read-only is defence in depth: automations only ever read from GitHub
  # (they write to Jira), so the server never even offers create_pull_request,
  # merge_pull_request or delete_file. ClaudeCliService::AUTOMATION_TOOLS is
  # still the primary allowlist; this makes a mistake there unable to write.
  def github_server
    {
      "type" => "stdio",
      "command" => GITHUB_MCP_COMMAND,
      "args" => [ "stdio", "--read-only" ],
      "env" => { "GITHUB_PERSONAL_ACCESS_TOKEN" => @creds.github_token }
    }
  end

  # Gated on a token that actually resolves (the project's, else the CLI's), so
  # a project with none gets no Figma server at all instead of one that fails on
  # its first call. The health check resolves it the same way, so the chip can
  # never claim Figma works for a run that was handed no Figma.
  def figma_server
    {
      "command" => "npx",
      "args" => [ "-y", "figma-developer-mcp", "--stdio" ],
      "env" => { "FIGMA_API_KEY" => @creds.figma_token }
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
