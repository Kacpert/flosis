class PrReviewJob < ApplicationJob
  queue_as :default

  CAPS = { "initial" => 4, "followup" => 2 }.freeze
  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  # The full PR-review prompt template used when a workspace hasn't customized
  # its own (Workspace#pr_review_prompt blank). Configurable from Configuration
  # -> AI (Task 9.1); this constant is also the textarea's seed value there.
  # The dynamic context is substituted via the {{TICKET}}/{{DIFF}}/{{CAP}}
  # tokens in build_prompt (double-brace tokens, chosen so they don't collide
  # with the single-brace JSON example at the tail). Keeping the tokens IN the
  # template — rather than appending context after the instructions — preserves
  # the exact ordering (ticket + diff between the persona and the INVESTIGATE
  # steps) of the pre-9.1 monolithic prompt.
  DEFAULT_PROMPT = <<~PROMPT.freeze
    You are a senior engineer reviewing a GitHub pull request. The repository is
    checked out in your current working directory. Be rigorous and skeptical,
    but VALUE THE READER'S TIME: it is far better to post one excellent comment,
    or none at all, than several shallow ones.

    {{TICKET}}

    Changed files and diffs:
    {{DIFF}}

    Before writing anything, INVESTIGATE — do not review from the diff alone:
    1. Open the changed files in the checkout and read the surrounding code to
       understand the actual logic, not just the changed lines.
    2. Run `git log -p` / `git blame` on the changed regions to learn WHY the
       code is the way it is and what recent changes touched it. Look for cases
       where this PR reverts a past fix, re-introduces a bug, or breaks an
       invariant established earlier.
    3. Trace how the changed code is USED elsewhere (grep for callers, related
       services/models) to catch broken contracts, missed call sites, or
       duplicated logic that already exists.

    Only after that, decide what (if anything) is worth raising. Post a comment
    ONLY when ALL of these hold:
    - It is a REAL, concrete problem: a bug, broken logic, a security or data-
      integrity issue, a contradiction with project history/invariants, or a
      clear miss against the Jira acceptance criteria.
    - You are highly confident it is correct (you verified it against the actual
      code/history, not a guess). If unsure, stay silent.
    - It genuinely helps the developer.

    Do NOT comment on style, naming, formatting, personal preference, or things
    a linter/CI would catch. Skip "consider"/"might want to" nits entirely.

    COMMENT STYLE — your readers are experienced developers; do NOT explain how
    the code works or re-narrate the diff. Be terse and direct:
    - State the problem and the fix in 1–2 short sentences (aim under ~40 words).
    - Reference symbols/methods by name; assume the reader can read the code.
    - No restating control flow, no "this happens because X then Y then Z", no
      padding. Think a senior dev's quick PR note, not an essay.
    - Example of the right length: "`@role_profile.save` returns false on
      validation errors but the surrounding `transaction` only rolls back on a
      raised exception, so the `find_or_create_by!` competency rows persist as
      orphans. Use `save!` (and rescue) or `raise ActiveRecord::Rollback`."

    Return ONLY a JSON array of AT MOST {{CAP}} items (fewer is better; an empty
    array is a perfectly good result when the PR is sound):
    {"path": "<file>", "line": <line number in the new file>,
     "comment": "<the problem + fix, terse, 1–2 sentences>"}.
  PROMPT

  def perform(workspace_id, pr_number, mode)
    workspace = Workspace.find_by(id: workspace_id)
    return unless workspace

    github = GithubClient.for(workspace)
    return unless github.configured?

    pr = github.pull_request(pr_number)
    return release_claim(workspace, pr_number, mode) unless pr
    if pr["draft"] || (pr["state"].present? && pr["state"] != "open")
      return release_claim(workspace, pr_number, mode)
    end

    head_sha = pr.dig("head", "sha")
    files = github.pull_request_files(pr_number)

    record = PrReview.find_or_initialize_by(workspace_id: workspace.id, pr_number: pr_number)
    record.update!(
      pr_title: pr["title"],
      pr_author: pr.dig("user", "login"),
      pr_branch: pr.dig("head", "ref"),
      pr_url: pr["html_url"]
    )

    issues = ai_issues(workspace, pr, files, mode)
    # The AI step failed to run (CLI/auth/transport). Record the failure against
    # this SHA so PrReviewCheckJob retries it a bounded number of times with a
    # backoff, instead of spending a full review every poll — don't post, don't
    # mark reviewed.
    return record.record_failure!(head_sha, @last_ai_error || "AI review failed") if issues.nil?

    # Since a followup re-reviews the whole cumulative diff, the AI re-flags issues
    # it already commented on. Drop any that duplicate an existing inline comment so
    # every push doesn't re-post the same comment.
    issues = reject_already_posted(github, pr_number, issues)

    issues = issues.first(CAPS.fetch(mode, 4))
    # A review GitHub refused is not a review: record the failure so it retries
    # with a backoff and shows up in the UI, instead of the PR being marked
    # reviewed with comments that never reached it.
    unless post_review(github, pr_number, issues)
      return record.record_failure!(head_sha, "GitHub rejected the review (see log for its reason)")
    end

    record.update!(record.failure_cleared_attributes.merge(
      last_reviewed_sha: head_sha,
      initial_done: true,
      reviewed_at: Time.current,
      outcome: issues.any? ? "comments" : "looks_good",
      comment_count: issues.size
    ))
  end

  private

  # Filters out issues that duplicate a comment already posted on the PR. The AI
  # only posts inline comments (bot login, from create_review), so we match new
  # issues against existing inline review comments by file + comment text. Line
  # numbers shift as the branch grows, so we key on path + a normalized body
  # rather than the exact line. Never raises — on any read failure it posts as
  # before (better a rare dupe than dropping a real review).
  def reject_already_posted(github, pr_number, issues)
    return issues if issues.blank?

    existing = github.pull_request_review_comments(pr_number)
    return issues if existing.blank?

    seen = existing.map { |c| dedup_key(c["path"], c["body"]) }.to_set
    issues.reject { |i| seen.include?(dedup_key(i[:path], i[:comment])) }
  rescue StandardError => e
    Rails.logger.warn("[PrReviewJob] dedup skipped: #{e.message}")
    issues
  end

  # A stable signature for "the same comment on the same file": path + the body
  # normalized (whitespace collapsed, our bot prefixes stripped, lowercased) so
  # trivial rewording/prefixing doesn't defeat the match.
  def dedup_key(path, body)
    normalized = body.to_s
      .gsub(/\s+/, " ")
      .strip
      .downcase
    [path.to_s, normalized]
  end

  # Undo the claim made by PrReviewCheckJob when there is NOTHING to review —
  # the PR vanished, went draft, or was closed. Not a failure, so it costs no
  # retry budget: an initial claim (no prior review) is deleted entirely, a
  # followup claim keeps the existing review but clears the in-flight SHA. A PR
  # in any of these states is no longer listed by open_pull_requests (or is
  # skipped as a draft), so this does not re-trigger an AI review.
  def release_claim(workspace, pr_number, mode)
    record = PrReview.find_by(workspace_id: workspace.id, pr_number: pr_number)
    return unless record
    if record.reviewed_at.nil?
      record.destroy
    else
      record.update!(enqueued_sha: nil)
    end
    nil
  end

  # Returns an array of {path,line,comment} hashes (possibly empty = "no issues,
  # post the no-issues review"), or nil ONLY when the AI step truly failed to run
  # (CLI error), so the caller retries next cycle instead of marking it reviewed.
  #
  # A successful run that finds nothing — whether it returns "[]" or just prose
  # saying the PR looks fine with no JSON array — is treated as zero issues, NOT
  # a failure. (Conflating the two caused clean PRs to be retried forever and
  # never get the "No issues found" review.)
  # Markers that mean the CLI did not actually review (auth/quota/transport
  # failures it prints as plain text instead of raising). These must NOT be
  # mistaken for "no issues" — otherwise an unauthenticated CLI silently posts
  # bogus "No issues found" reviews on unreviewed PRs.
  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def ai_issues(workspace, pr, files, mode)
    prompt = build_prompt(workspace, pr, files, mode)
    response = ClaudeCliService.new(codebase_path: CODEBASE_PATH).start_session(prompt: prompt)[:response].to_s
    json = extract_json(response)

    if json.nil?
      # No JSON array. Distinguish a genuine "looks fine" verdict from a CLI
      # failure: a real review is substantive prose; an auth/quota error is a
      # short error string. Treat failures as nil (retry, do not post/mark).
      if cli_failed?(response)
        @last_ai_error = "AI returned no review: #{response.strip.truncate(120).presence || 'empty response'}"
        return nil
      end
      return [] # CLI ran and found nothing worth flagging
    end

    parsed = JSON.parse(json)
    return [] unless parsed.is_a?(Array)
    parsed.filter_map do |h|
      next unless h.is_a?(Hash) && h["path"].present? && h["line"] && h["comment"].present?
      { path: h["path"], line: h["line"].to_i, comment: h["comment"].to_s }
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[PrReviewJob] claude error: #{e.message}")
    @last_ai_error = e.message
    nil
  rescue JSON::ParserError
    []
  end

  # True when the response indicates the CLI failed to run a real review rather
  # than legitimately finding nothing.
  def cli_failed?(response)
    response.match?(CLI_FAILURE_MARKERS) || response.strip.length < 40
  end

  # Return the first JSON array in the response, or nil if there is none.
  def extract_json(text)
    text.to_s[/\[.*\]/m]
  end

  def build_prompt(workspace, pr, files, mode)
    key = PrJiraKey.extract(branch: pr.dig("head", "ref"), title: pr["title"], body: pr["body"])
    task = key ? Task.find_by(external_reference: key) : nil
    ticket = if task
      "Linked Jira ticket #{key}:\nTitle: #{task.name}\nDescription: #{task.description}"
    else
      "No linked Jira ticket."
    end
    cap = CAPS.fetch(mode, 4)
    diff = files.map { |f| "FILE: #{f['filename']}\n#{f['patch']}" }.join("\n\n")
    template = workspace.pr_review_prompt.presence || DEFAULT_PROMPT

    # Substitute the dynamic context into the (default or custom) template.
    # A custom prompt without the tokens simply won't have them replaced —
    # acceptable, since an admin editing the seeded default keeps the tokens.
    template
      .gsub("{{TICKET}}", ticket)
      .gsub("{{DIFF}}", diff)
      .gsub("{{CAP}}", cap.to_s)
  end

  # Returns true when GitHub accepted the review.
  #
  # An inline comment is rejected outright (422) when its line is not part of
  # the diff — a line number the AI took from the file rather than the changed
  # hunk is enough, and GitHub then drops the WHOLE review, every comment with
  # it. That happened on PRs 1214, 1233, 1268 and 1273: the review was written,
  # thrown away by GitHub, and recorded here as posted.
  #
  # So a rejected inline review is retried as a plain one with the findings in
  # its body. Less precise than a comment pinned to a line, but the developer
  # gets the review instead of silence.
  def post_review(github, pr_number, issues)
    return github.create_review(pr_number, body: "🤖 No issues found 👍", event: "COMMENT", comments: []) if issues.empty?

    comments = issues.map { |i| { path: i[:path], line: i[:line], side: "RIGHT", body: i[:comment] } }
    return true if github.create_review(pr_number, body: "🤖 Automated AI review", event: "COMMENT", comments: comments)

    Rails.logger.warn("[PrReviewJob] inline review rejected for ##{pr_number} — retrying without inline comments")
    github.create_review(pr_number, body: fallback_review_body(issues), event: "COMMENT", comments: [])
  end

  # The findings as one message, each with the file and line it refers to, since
  # they can no longer be pinned to the diff.
  def fallback_review_body(issues)
    lines = issues.map { |i| "- **`#{i[:path]}:#{i[:line]}`** — #{i[:comment]}" }
    "🤖 Automated AI review\n\n" \
      "(couldn't attach these to the diff — GitHub rejected the line references)\n\n" +
      lines.join("\n")
  end
end
