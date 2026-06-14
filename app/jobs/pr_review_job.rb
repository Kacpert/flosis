class PrReviewJob < ApplicationJob
  queue_as :default

  CAPS = { "initial" => 4, "followup" => 2 }.freeze
  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  def perform(workspace_id, pr_number, mode)
    workspace = Workspace.find_by(id: workspace_id)
    return unless workspace

    github = GithubClient.for(workspace)
    return unless github.configured?

    pr = github.pull_request(pr_number)
    return unless pr
    return if pr["draft"]
    return if pr["state"].present? && pr["state"] != "open"

    head_sha = pr.dig("head", "sha")
    files = github.pull_request_files(pr_number)

    issues = ai_issues(pr, files, mode)
    return if issues.nil? # parse failure → do not advance SHA, retry next cycle

    issues = issues.first(CAPS.fetch(mode, 4))
    post_review(github, pr_number, issues)

    record = PrReview.find_or_initialize_by(workspace_id: workspace.id, pr_number: pr_number)
    record.update!(last_reviewed_sha: head_sha, initial_done: true, reviewed_at: Time.current)
  end

  private

  # Returns an array of {path,line,comment} hashes, or nil if the AI output
  # couldn't be parsed (so the caller can avoid marking the PR reviewed).
  def ai_issues(pr, files, mode)
    prompt = build_prompt(pr, files, mode)
    response = ClaudeCliService.new(codebase_path: CODEBASE_PATH).start_session(prompt: prompt)[:response]
    parsed = JSON.parse(extract_json(response))
    return nil unless parsed.is_a?(Array)
    parsed.filter_map do |h|
      next unless h.is_a?(Hash) && h["path"].present? && h["line"] && h["comment"].present?
      { path: h["path"], line: h["line"].to_i, comment: h["comment"].to_s }
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[PrReviewJob] claude error: #{e.message}")
    nil
  rescue JSON::ParserError
    nil
  end

  # Pull the first JSON array out of the response (the CLI may wrap prose around it).
  def extract_json(text)
    text.to_s[/\[.*\]/m] || text.to_s
  end

  def build_prompt(pr, files, mode)
    key = PrJiraKey.extract(branch: pr.dig("head", "ref"), title: pr["title"], body: pr["body"])
    task = key ? Task.find_by(external_reference: key) : nil
    ticket = if task
      "Linked Jira ticket #{key}:\nTitle: #{task.name}\nDescription: #{task.description}"
    else
      "No linked Jira ticket."
    end
    cap = CAPS.fetch(mode, 4)
    diff = files.map { |f| "FILE: #{f['filename']}\n#{f['patch']}" }.join("\n\n")
    <<~PROMPT
      You are reviewing a GitHub pull request. Use the repository in the current
      working directory (you may read files and run `git log`/`git blame`).

      #{ticket}

      Changed files and diffs:
      #{diff}

      Return ONLY a JSON array of at most #{cap} items, each the MOST important
      issue: {"path": "<file>", "line": <line number in the new file>,
      "comment": "<concise, actionable review comment>"}. Prioritise correctness,
      security, data integrity, and missed acceptance criteria. Skip style nits.
      If nothing important, return [].
    PROMPT
  end

  def post_review(github, pr_number, issues)
    if issues.empty?
      github.create_review(pr_number, body: "🤖 No issues found 👍", event: "COMMENT", comments: [])
    else
      comments = issues.map { |i| { path: i[:path], line: i[:line], side: "RIGHT", body: i[:comment] } }
      github.create_review(pr_number, body: "🤖 Automated AI review", event: "COMMENT", comments: comments)
    end
  end
end
