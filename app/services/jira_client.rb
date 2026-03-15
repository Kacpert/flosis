require "net/http"
require "json"
require "base64"

class JiraClient
  TIMEOUT = 10
  PROJECT_KEY_FORMAT = /\A[A-Z][A-Z0-9_]+\z/

  def initialize(domain: ENV["JIRA_DOMAIN"], email: ENV["JIRA_EMAIL"], api_token: ENV["JIRA_API_TOKEN"])
    @domain = domain
    @email = email
    @api_token = api_token
  end

  def fetch_projects
    results = []
    start_at = 0

    loop do
      data = get("/rest/api/3/project/search", startAt: start_at, maxResults: 50)
      return [] unless data

      values = data["values"] || []
      results.concat(values.map { |p| { key: p["key"], name: p["name"], id: p["id"] } })

      break if data["isLast"] != false
      start_at += values.length
    end

    results
  end

  def fetch_issues(project_key)
    return [] unless project_key.match?(PROJECT_KEY_FORMAT)

    results = []
    next_page_token = nil

    loop do
      body = {
        jql: "project = #{project_key} AND statusCategory != Done ORDER BY status ASC, updated DESC",
        fields: ["summary", "status", "assignee"],
        maxResults: 100
      }
      body[:nextPageToken] = next_page_token if next_page_token

      data = post("/rest/api/3/search/jql", body)
      return [] unless data

      issues = data["issues"] || []
      results.concat(issues.map { |i| parse_issue(i) })

      break if data["nextPageToken"].nil?
      next_page_token = data["nextPageToken"]
    end

    results
  end

  private

  def parse_issue(issue)
    fields = issue["fields"] || {}
    status = fields.dig("status", "statusCategory") || {}

    {
      key: issue["key"],
      summary: fields["summary"],
      status_category: status["key"],
      status_name: fields.dig("status", "name"),
      assignee_email: fields.dig("assignee", "emailAddress"),
      url: "https://#{@domain}/browse/#{issue['key']}"
    }
  end

  def post(path, body = {})
    uri = URI("https://#{@domain}#{path}")

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{@email}:#{@api_token}")}"
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = body.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      Rails.logger.warn("[JiraClient] API error: #{response.code} #{response.message} for #{path}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.warn("[JiraClient] Connection error: #{e.message}")
    nil
  end

  def get(path, params = {})
    uri = URI("https://#{@domain}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{@email}:#{@api_token}")}"
    request["Accept"] = "application/json"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    else
      Rails.logger.warn("[JiraClient] API error: #{response.code} #{response.message} for #{path}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.warn("[JiraClient] Connection error: #{e.message}")
    nil
  end
end
