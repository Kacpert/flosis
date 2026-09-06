require "net/http"
require "json"

# Minimal GitHub REST client for the PR reviewer. Per-workspace token + repo.
# Used inside background jobs (no MCP available there).
class GithubClient
  API_BASE = "https://api.github.com".freeze
  TIMEOUT  = 15

  def self.for(workspace)
    new(token: workspace&.github_token, repo: workspace&.github_repo)
  end

  # Resolver-backed variant for per-project automations. Leaves the existing
  # workspace-based `for` untouched (used by legacy PrReviewJob).
  def self.for_project(project)
    creds = ProjectCredentials.new(project)
    new(token: creds.github_token, repo: creds.github_repo)
  end

  def initialize(token: nil, repo: nil)
    @token = token
    @repo = repo
  end

  def configured?
    @token.present? && @repo.present?
  end

  def open_pull_requests
    get("/repos/#{@repo}/pulls?state=open&per_page=50") || []
  end

  def pull_request(number)
    get("/repos/#{@repo}/pulls/#{number}")
  end

  def pull_request_commits(number)
    get("/repos/#{@repo}/pulls/#{number}/commits?per_page=100") || []
  end

  def pull_request_files(number)
    get("/repos/#{@repo}/pulls/#{number}/files?per_page=100") || []
  end

  # Existing inline review comments on the PR (across all prior reviews). Used to
  # avoid re-posting the same comment on every push. Each entry has path, line
  # (or original_line for outdated hunks), and body.
  def pull_request_review_comments(number)
    all = []
    page = 1
    loop do
      batch = get("/repos/#{@repo}/pulls/#{number}/comments?per_page=100&page=#{page}")
      break if batch.blank?
      all.concat(batch)
      break if batch.size < 100
      page += 1
    end
    all
  end

  def create_review(number, body:, event:, comments:)
    payload = { event: event, body: body }
    payload[:comments] = comments if comments.present?
    post("/repos/#{@repo}/pulls/#{number}/reviews", payload)
  end

  # Returns { ok: true } or { ok: false, error: "..." }. Never raises.
  def health_check
    response = raw(:get, "/repos/#{@repo}")
    return { ok: true } if response.is_a?(Net::HTTPSuccess)
    { ok: false, error: "#{response.code} #{response.message}" }
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    { ok: false, error: e.message }
  end

  private

  def get(path)
    response = raw(:get, path)
    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, JSON::ParserError => e
    Rails.logger.error("[GithubClient] GET #{path} failed: #{e.message}")
    nil
  end

  def post(path, payload)
    response = raw(:post, path, payload.to_json)
    return true if response.is_a?(Net::HTTPSuccess)

    # The body is the only place GitHub says WHY. A 422 on a review is usually
    # "line must be part of the diff" — the status alone left that guesswork.
    Rails.logger.error(
      "[GithubClient] POST #{path} failed: #{response.code} #{response.message} #{response.body.to_s.truncate(400)}"
    )
    false
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.error("[GithubClient] POST #{path} error: #{e.message}")
    false
  end

  def raw(method, path, body = nil)
    uri = URI("#{API_BASE}#{path}")
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "Clar-PR-Reviewer"
    request["Content-Type"] = "application/json" if method == :post
    request.body = body if body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    http.request(request)
  end
end
