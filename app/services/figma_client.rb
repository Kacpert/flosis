require "net/http"
require "json"

# Just enough Figma to answer "can the AI actually read a frame right now?".
#
# The AI reaches Figma through the figma-developer-mcp server, whose token lives
# in the Claude CLI's own config — NOT in our database, so there is nothing on
# the workspace to check. This reads the very token that server would use, which
# is the only way the answer can be true rather than merely plausible.
#
# It matters because that token EXPIRES: Figma personal access tokens are issued
# with a lifetime, and when one lapses the AI just says it could not open the
# link, in the middle of a conversation with a client.
class FigmaClient
  API_BASE = "https://api.figma.com".freeze
  TIMEOUT = 10
  # Where the CLI keeps its global MCP servers. Overridable so a different
  # deployment (or a test) can point elsewhere.
  CONFIG_PATH = ENV.fetch("CLAUDE_CLI_CONFIG", File.expand_path("~/.claude.json")).freeze

  def self.for_cli
    new(token: cli_token)
  end

  # The API key the figma MCP server is configured with, or nil when Figma isn't
  # wired up at all. ENV wins, so a deployment can set it explicitly.
  def self.cli_token
    return ENV["FIGMA_API_KEY"] if ENV["FIGMA_API_KEY"].present?
    return nil unless File.exist?(CONFIG_PATH)

    config = JSON.parse(File.read(CONFIG_PATH))
    config.dig("mcpServers", "figma", "env", "FIGMA_API_KEY").presence
  rescue JSON::ParserError, Errno::EACCES => e
    Rails.logger.warn("[FigmaClient] couldn't read #{CONFIG_PATH}: #{e.message}")
    nil
  end

  def initialize(token:)
    @token = token
  end

  def configured?
    @token.present?
  end

  # { ok: true } or { ok: false, error: "..." }. Never raises — a health check
  # that can take the page down with it is worse than no health check.
  def health_check
    return { ok: false, error: "No Figma API key configured" } unless configured?

    uri = URI("#{API_BASE}/v1/me")
    request = Net::HTTP::Get.new(uri)
    request["X-Figma-Token"] = @token

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                               open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.request(request) }
    return { ok: true } if response.is_a?(Net::HTTPSuccess)

    { ok: false, error: figma_error(response) }
  rescue StandardError => e
    { ok: false, error: "#{e.class}: #{e.message}" }
  end

  private

  # Figma answers with {"status":401,"err":"Token has expired"} — say that,
  # rather than a bare 401 nobody can act on.
  def figma_error(response)
    detail = JSON.parse(response.body.to_s)["err"] rescue nil
    [ "#{response.code} #{response.message}", detail ].compact.join(" — ")
  end
end
