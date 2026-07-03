require "net/http"
require "json"

# Posts a message to a Discord incoming webhook (app_rules' notify channel —
# distinct from DiscordGroupClient, which posts to a group DM via a
# user-account token). A webhook failure must NEVER crash the caller (the
# AlertRuleRunJob run itself still needs to be recorded) — every error path is
# rescued and returned as a result hash instead of raised.
class DiscordWebhookClient
  TIMEOUT = 10

  # Returns { ok: true } on success, or { ok: false, error: "…" } on any
  # failure (never raises).
  def self.post(url, content:)
    new.post(url, content: content)
  end

  def post(url, content:)
    return { ok: false, error: "missing webhook url" } if url.blank?

    uri = URI(url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { content: content }.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(request)
    return { ok: true } if response.is_a?(Net::HTTPSuccess)

    Rails.logger.error("[DiscordWebhookClient] post failed: #{response.code} #{response.message}")
    { ok: false, error: "#{response.code} #{response.message}" }
  rescue StandardError => e
    Rails.logger.error("[DiscordWebhookClient] post error: #{e.class}: #{e.message}")
    { ok: false, error: e.message }
  end
end
