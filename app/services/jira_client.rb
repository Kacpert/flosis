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
        fields: ["summary", "status", "assignee", "description", "priority", "issuetype", "labels", "reporter", "sprint", "timeoriginalestimate"],
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

  def fetch_boards(project_key)
    return [] unless project_key.match?(PROJECT_KEY_FORMAT)

    results = []
    start_at = 0

    loop do
      data = get("/rest/agile/1.0/board", startAt: start_at, maxResults: 50)
      return [] unless data

      values = data["values"] || []
      values.each do |b|
        next unless b.dig("location", "projectKey") == project_key

        results << { id: b["id"], name: b["name"], type: b["type"] }
      end

      break if data["isLast"] != false
      start_at += values.length
    end

    results
  end

  def fetch_board_configuration(board_id)
    data = get("/rest/agile/1.0/board/#{board_id}/configuration")
    return [] unless data

    columns = data.dig("columnConfig", "columns") || []
    columns.map do |col|
      {
        name: col["name"],
        statuses: (col["statuses"] || []).map { |s| { id: s["id"] } }
      }
    end
  end

  def fetch_sprint_issue_keys(sprint_id)
    results = []
    start_at = 0

    loop do
      data = get("/rest/agile/1.0/sprint/#{sprint_id}/issue", fields: "summary", maxResults: 100, startAt: start_at)
      return [] unless data

      issues = data["issues"] || []
      results.concat(issues.map { |i| i["key"] })

      break if start_at + issues.length >= (data["total"] || 0)
      start_at += issues.length
    end

    results
  end

  def fetch_statuses
    data = get("/rest/api/3/status")
    return {} unless data.is_a?(Array)

    data.each_with_object({}) { |s, map| map[s["id"]] = s["name"] }
  end

  def fetch_sprints(board_id)
    results = []
    start_at = 0

    loop do
      data = get("/rest/agile/1.0/board/#{board_id}/sprint", startAt: start_at, maxResults: 50)
      return [] unless data

      values = data["values"] || []
      results.concat(values.map { |s|
        {
          id: s["id"],
          name: s["name"],
          state: s["state"],
          start_date: s["startDate"],
          end_date: s["endDate"]
        }
      })

      break if data["isLast"] != false
      start_at += values.length
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
      assignee_name: fields.dig("assignee", "displayName"),
      url: "https://#{@domain}/browse/#{issue['key']}",
      description: adf_to_text(fields["description"]),
      description_adf: fields["description"]&.to_json,
      priority: fields.dig("priority", "name"),
      issue_type: fields.dig("issuetype", "name"),
      labels: fields["labels"] || [],
      reporter_email: fields.dig("reporter", "emailAddress"),
      reporter_name: fields.dig("reporter", "displayName"),
      sprint_id: fields.dig("sprint", "id"),
      sprint_name: fields.dig("sprint", "name"),
      time_estimate_seconds: fields["timeoriginalestimate"]
    }
  end

  def adf_to_text(node)
    return nil if node.nil?
    return node["text"] if node["type"] == "text"

    content = node["content"]
    return "" unless content.is_a?(Array)

    parts = content.map { |child| adf_to_text(child) }.compact

    case node["type"]
    when "doc"
      parts.join("\n\n")
    when "paragraph", "heading", "blockquote", "codeBlock"
      parts.join
    when "bulletList", "orderedList"
      parts.map { |p| "- #{p}" }.join("\n")
    when "listItem"
      parts.join
    else
      parts.join
    end
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
