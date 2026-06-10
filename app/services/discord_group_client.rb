require "net/http"
require "json"

# Posts messages to a Discord group DM using a user-account token (group DMs
# cannot use webhooks or bot tokens). Token + channel id are stored per-workspace
# (workspaces.discord_user_token / discord_channel_id) and entered in Workspace
# Settings.
class DiscordGroupClient
  API_BASE = "https://discord.com/api/v10".freeze
  TIMEOUT  = 10

  # Build a client from a workspace's stored Discord settings.
  def self.for(workspace)
    new(token: workspace&.discord_user_token, channel_id: workspace&.discord_channel_id)
  end

  def initialize(token: nil, channel_id: nil)
    @token = token
    @channel_id = channel_id
  end

  def configured?
    @token.present? && @channel_id.present?
  end

  # Returns true on success, false (logged) on any failure. Never raises.
  def post(content)
    return false unless configured?

    uri = URI("#{API_BASE}/channels/#{@channel_id}/messages")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = @token # raw user token, no "Bot " prefix
    request["Content-Type"] = "application/json"
    request["User-Agent"] = "Clar (https://clar.rubyonsaas.com, 1.0)"
    request.body = { content: content }.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(request)
    return true if response.is_a?(Net::HTTPSuccess)

    Rails.logger.error("[DiscordGroupClient] post failed: #{response.code} #{response.message}")
    false
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.error("[DiscordGroupClient] post error: #{e.message}")
    false
  end
end
