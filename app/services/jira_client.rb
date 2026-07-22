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

  def fetch_issues(project_key, story_points_field_id: nil)
    return [] unless project_key.match?(PROJECT_KEY_FORMAT)

    results = []
    next_page_token = nil
    fields = ["summary", "status", "assignee", "description", "priority", "issuetype", "labels", "reporter", "sprint", "timeoriginalestimate", "attachment", "updated", "created"]
    fields << story_points_field_id if story_points_field_id.present?

    loop do
      body = {
        jql: "project = #{project_key} AND statusCategory != Done ORDER BY status ASC, updated DESC",
        fields: fields,
        maxResults: 100
      }
      body[:nextPageToken] = next_page_token if next_page_token

      data = post("/rest/api/3/search/jql", body)
      return [] unless data

      issues = data["issues"] || []
      results.concat(issues.map { |i| parse_issue(i, story_points_field_id: story_points_field_id) })

      break if data["nextPageToken"].nil?
      next_page_token = data["nextPageToken"]
    end

    results
  end

  # A second, lightweight pass for recently-DONE issues, used to populate the
  # `delivered_issues` reporting mirror (never `tasks` — see DeliveredIssue).
  # Deliberately excludes comments/attachments fields to keep the payload small
  # across a ~400-day window.
  def fetch_recent_done_issues(project_key, since: "-400d", story_points_field_id: nil)
    return [] unless project_key.match?(PROJECT_KEY_FORMAT)

    results = []
    next_page_token = nil
    fields = ["summary", "issuetype", "assignee", "reporter", "created", "resolutiondate"]
    fields << story_points_field_id if story_points_field_id.present?

    loop do
      body = {
        jql: "project = #{project_key} AND statusCategory = Done AND updated >= #{since} ORDER BY updated DESC",
        fields: fields,
        maxResults: 100
      }
      body[:nextPageToken] = next_page_token if next_page_token

      data = post("/rest/api/3/search/jql", body)
      return [] unless data

      issues = data["issues"] || []
      results.concat(issues.map { |i| parse_done_issue(i, story_points_field_id: story_points_field_id) })

      break if data["nextPageToken"].nil?
      next_page_token = data["nextPageToken"]
    end

    results
  end

  # Finds the custom field id for Jira's story-points field ("Story point
  # estimate" on team-managed/next-gen projects, "Story Points" on
  # company-managed/classic projects) via the existing #fetch_field_id lookup.
  # Caching (on workspace.jira_story_points_field_id) is the caller's
  # responsibility — mirrors how JiraWriter caches jira_ai_actions_field_id.
  def resolve_story_points_field
    fetch_field_id("Story point estimate") || fetch_field_id("Story Points")
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

  # Fetch every comment for an issue via the dedicated endpoint, paginating.
  # The embedded "comment" field in /issue/{key} is capped at 100, so busy
  # tickets silently lose tail comments — this method handles that.
  def fetch_all_comments(issue_key)
    results = []
    start_at = 0
    loop do
      data = get("/rest/api/3/issue/#{issue_key}/comment", startAt: start_at, maxResults: 100)
      return [] unless data
      batch = data["comments"] || []
      results.concat(batch)
      start_at += batch.size
      total = data["total"].to_i
      break if start_at >= total || batch.empty?
    end
    parse_comments(results)
  end

  # Download a Jira attachment's binary content. `url` is the authenticated
  # content URL from the issue payload.
  def download_attachment(url)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{@email}:#{@api_token}")}"
    request["Accept"] = "*/*"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = TIMEOUT
    http.read_timeout = 30

    response = http.request(request)

    case response
    when Net::HTTPRedirection
      download_redirect(response["Location"])
    when Net::HTTPSuccess
      response.body
    else
      Rails.logger.warn("[JiraClient] Attachment download failed: #{response.code} #{response.message}")
      nil
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    Rails.logger.warn("[JiraClient] Attachment download error: #{e.message}")
    nil
  end

  # ---- writes (use the same global creds) ------------------------------

  def create_issue(project_key:, summary:, description_text:, issue_type: "Task")
    body = {
      fields: {
        project: { key: project_key },
        summary: summary.to_s,
        issuetype: { name: issue_type },
        description: description_doc(description_text)
      }
    }
    data = post_raw("/rest/api/3/issue", body)
    return { ok: false, error: data[:error] } unless data[:ok]
    key = data[:json]["key"]
    { ok: true, key: key, url: "https://#{@domain}/browse/#{key}" }
  end

  def update_issue_description(issue_key:, description_text:)
    body = { fields: { description: description_doc(description_text) } }
    res = put("/rest/api/3/issue/#{issue_key}", body)
    res[:ok] ? { ok: true } : { ok: false, error: res[:error] }
  end

  # Sets a multi-checkbox "AI actions"-style option field. The field's option
  # names in Jira can differ from what we intend by typos/spacing/case (real
  # example: our "Briefed" vs Jira's "Brifed", our "Detailed" vs Jira's
  # "Details Gathered "). So we resolve our intended value against the field's
  # ACTUAL allowed options (matched leniently) and send Jira's exact option —
  # by id when we can, else the exact value string. Falls back to the raw value
  # if we can't read the options (behaviour unchanged in that case).
  def add_ai_action(issue_key:, field_id:, value:)
    option = resolve_field_option(issue_key, field_id, value)
    payload = if option && option["id"]
      { "id" => option["id"] }
    elsif option && option["value"]
      { "value" => option["value"] }
    else
      { "value" => value }
    end

    body = { fields: { field_id => [ payload ] } }
    res = put("/rest/api/3/issue/#{issue_key}", body)
    res[:ok] ? { ok: true } : { ok: false, error: res[:error] }
  end

  # Returns the field's allowed option ({"value"=>, "id"=>}) that best matches
  # `intended`, tolerant of case/whitespace/punctuation AND small typos. Handles
  # the real cases seen: "Briefed"→"Brifed" (a typo, needs edit-distance) and
  # "Detailed"→"Details Gathered " (a prefix + extra words). nil if options can't
  # be read or nothing is close enough (caller then sends the raw value).
  def resolve_field_option(issue_key, field_id, intended)
    data = get("/rest/api/3/issue/#{issue_key}/editmeta")
    options = data&.dig("fields", field_id, "allowedValues")
    return nil unless options.is_a?(Array) && options.any?

    want = normalize_option(intended)

    # 1. exact (normalized) match.
    exact = options.find { |o| normalize_option(o["value"]) == want }
    return exact if exact

    # 2. one is a prefix of the other — catches "detailed" vs "detailsgathered"
    #    (share the "detail" stem) as long as the shorter is >= 4 chars.
    prefix = options.find do |o|
      n = normalize_option(o["value"])
      short, long = [ want, n ].sort_by(&:length)
      short.length >= 4 && long.start_with?(short[0, [ short.length, 5 ].min])
    end
    return prefix if prefix

    # 3. closest by edit distance, within a small threshold — catches "briefed"
    #    vs "brifed" (distance 1).
    best = options.min_by { |o| levenshtein(want, normalize_option(o["value"])) }
    return best if best && levenshtein(want, normalize_option(best["value"])) <= 2

    nil
  end

  def normalize_option(str)
    str.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end

  def levenshtein(a, b)
    return b.length if a.empty?
    return a.length if b.empty?
    prev = (0..b.length).to_a
    a.each_char.with_index do |ca, i|
      cur = [ i + 1 ]
      b.each_char.with_index do |cb, j|
        cur << [ prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1) ].min
      end
      prev = cur
    end
    prev.last
  end

  def fetch_field_id(name)
    data = get("/rest/api/3/field")
    return nil unless data.is_a?(Array)
    field = data.find { |f| f["name"].to_s.casecmp?(name.to_s) }
    field && field["id"]
  end

  # Sets a numeric custom field (e.g. story points) on an issue. Same
  # never-raises {ok:, error:} contract as update_issue_description.
  def set_number_field(issue_key:, field_id:, value:)
    body = { fields: { field_id => value } }
    res = put("/rest/api/3/issue/#{issue_key}", body)
    res[:ok] ? { ok: true } : { ok: false, error: res[:error] }
  end

  private

  # Minimal ADF document wrapping plain text in a single paragraph.
  # Build the ADF description. The brief/draft text is lightweight Markdown
  # (**bold**, "- " bullets, headings, links); convert it to real ADF nodes so
  # Jira renders it instead of showing raw "**...**" / "- ..." text.
  def description_doc(text)
    MarkdownToAdf.call(text)
  end

  # POST that distinguishes success from failure (unlike #post, which returns
  # nil on error). Used by writes that need the error surfaced.
  def post_raw(path, body)
    response = http_request(Net::HTTP::Post, path, body)
    if response.is_a?(Net::HTTPSuccess)
      { ok: true, json: (JSON.parse(response.body) rescue {}) }
    else
      { ok: false, error: "#{response.code} #{response.message}" }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    { ok: false, error: e.message }
  end

  def put(path, body)
    response = http_request(Net::HTTP::Put, path, body)
    if response.is_a?(Net::HTTPSuccess)
      { ok: true }
    else
      { ok: false, error: "#{response.code} #{response.message}" }
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    { ok: false, error: e.message }
  end

  # Shared request builder for write verbs.
  def http_request(verb_class, path, body)
    uri = URI("https://#{@domain}#{path}")
    request = verb_class.new(uri)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{@email}:#{@api_token}")}"
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json"
    request.body = body.to_json

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    http.request(request)
  end

  def download_redirect(url)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    # Signed S3 URL — no auth header needed (and would break the signature)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = TIMEOUT
    http.read_timeout = 30

    response = http.request(request)
    response.is_a?(Net::HTTPSuccess) ? response.body : nil
  end

  def parse_issue(issue, story_points_field_id: nil)
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
      time_estimate_seconds: fields["timeoriginalestimate"],
      updated: fields["updated"],
      story_points: story_points_field_id.present? ? fields[story_points_field_id] : nil,
      jira_created_at: fields["created"],
      attachments: parse_attachments(fields["attachment"])
    }
  end

  # Lightweight parse for the done-issues pass — no attachments/description.
  def parse_done_issue(issue, story_points_field_id: nil)
    fields = issue["fields"] || {}

    {
      key: issue["key"],
      title: fields["summary"],
      issue_type: fields.dig("issuetype", "name"),
      assignee_email: fields.dig("assignee", "emailAddress"),
      assignee_name: fields.dig("assignee", "displayName"),
      reporter_email: fields.dig("reporter", "emailAddress"),
      reporter_name: fields.dig("reporter", "displayName"),
      story_points: story_points_field_id.present? ? fields[story_points_field_id] : nil,
      jira_created_at: fields["created"],
      resolved_at: fields["resolutiondate"]
    }
  end

  def parse_comments(list)
    return [] unless list.is_a?(Array)

    list.map do |c|
      {
        jira_id: c["id"],
        author_name: c.dig("author", "displayName"),
        author_email: c.dig("author", "emailAddress"),
        body: adf_to_text(c["body"]),
        body_adf: c["body"]&.to_json,
        created: c["created"],
        updated: c["updated"]
      }
    end
  end

  def parse_attachments(list)
    return [] unless list.is_a?(Array)

    list.map do |a|
      {
        jira_id: a["id"],
        filename: a["filename"],
        mime_type: a["mimeType"],
        size: a["size"],
        content_url: a["content"],
        created: a["created"]
      }
    end
  end

  def adf_to_text(node)
    return nil if node.nil?
    return node["text"] if node["type"] == "text"

    case node["type"]
    when "inlineCard", "embedCard", "blockCard"
      url = node.dig("attrs", "url")
      return url.to_s if url
      return ""
    when "hardBreak"
      return "\n"
    end

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
