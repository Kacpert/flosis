require "net/http"
require "json"
require "base64"
require "cgi"

# Minimal GitHub REST client for the PR reviewer. Per-workspace token + repo.
# Used inside background jobs (no MCP available there).
class GithubClient
  API_BASE = "https://api.github.com".freeze
  TIMEOUT  = 15

  # What the Git Data API calls below raise on anything but a success: GitHub's
  # status (nil when it never answered) and its reason.
  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  # The project's own repo and token. There is no workspace-level variant any
  # more: the workspace stopped carrying credentials when the configuration
  # moved onto projects, and a shared token was how one client's repository
  # could be reviewed with another client's key.
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

  # The Git Data API, for a task's branch (TaskBranch, 2026-11-21). Unlike the
  # reviewer's calls above, these raise GithubClient::Error: a branch is a
  # chain of writes, and one that fails must stop it.
  def default_branch
    request!(:get, "/repos/#{@repo}")["default_branch"]
  end

  # A branch's head, or nil when GitHub has no such branch.
  def branch_sha(name)
    request!(:get, "/repos/#{@repo}/git/ref/heads/#{name}", allow_missing: true)&.dig("object", "sha")
  end

  def commit_tree_sha(sha)
    request!(:get, "/repos/#{@repo}/git/commits/#{sha}").dig("tree", "sha")
  end

  # The files directly in a folder of a branch, [] when there is none.
  def folder_paths(path, ref:)
    data = request!(:get, "/repos/#{@repo}/contents/#{path}?ref=#{CGI.escape(ref).gsub('%2F', '/')}", allow_missing: true)
    data.is_a?(Array) ? data.select { |entry| entry["type"] == "file" }.map { |entry| entry["path"] } : []
  end

  def create_blob(bytes)
    request!(:post, "/repos/#{@repo}/git/blobs", { content: Base64.strict_encode64(bytes.to_s.b), encoding: "base64" })["sha"]
  end

  def create_tree(base_tree:, entries:)
    request!(:post, "/repos/#{@repo}/git/trees", { base_tree: base_tree, tree: entries })["sha"]
  end

  def create_commit(message:, tree:, parents:)
    request!(:post, "/repos/#{@repo}/git/commits", { message: message, tree: tree, parents: parents })["sha"]
  end

  def create_ref(name, sha)
    request!(:post, "/repos/#{@repo}/git/refs", { ref: "refs/heads/#{name}", sha: sha })
  end

  # Moves a branch forward; GitHub refuses anything but a fast-forward.
  def update_ref(name, sha)
    request!(:patch, "/repos/#{@repo}/git/refs/heads/#{name}", { sha: sha, force: false })
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

  def request!(method, path, payload = nil, allow_missing: false)
    response = raw(method, path, payload&.to_json)
    return nil if allow_missing && response.code == "404"
    unless response.is_a?(Net::HTTPSuccess)
      reason = (JSON.parse(response.body.to_s)["message"] rescue nil).presence || response.message
      raise Error.new("#{response.code} #{reason}", status: response.code.to_i)
    end

    response.body.present? ? JSON.parse(response.body) : {}
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, JSON::ParserError => e
    raise Error, "GitHub did not answer: #{e.message}"
  end

  def raw(method, path, body = nil)
    uri = URI("#{API_BASE}#{path}")
    request = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method).new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "Clar-PR-Reviewer"
    request["Content-Type"] = "application/json" if method != :get
    request.body = body if body

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    http.request(request)
  end
end
