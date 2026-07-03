class PrReviewJob < ApplicationJob
  queue_as :default

  CAPS = { "initial" => 4, "followup" => 2 }.freeze
  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  # The static persona/instructions used when a workspace hasn't customized its
  # PR review prompt (Workspace#pr_review_prompt blank). Configurable from
  # Configuration -> AI (Task 9.1); this constant is also the textarea's seed
  # value there. The dynamic pr/files/mode context is interpolated separately
  # in build_prompt, appended after whichever base (custom or default) applies.
  DEFAULT_PROMPT = <<~PROMPT.freeze
    You are a senior engineer reviewing a GitHub pull request. The repository is
    checked out in your current working directory. Be rigorous and skeptical,
    but VALUE THE READER'S TIME: it is far better to post one excellent comment,
    or none at all, than several shallow ones.

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
    # parse failure → release the claim so the next cycle retries (don't post,
    # don't mark reviewed).
    return release_claim(workspace, pr_number, mode) if issues.nil?

    issues = issues.first(CAPS.fetch(mode, 4))
    post_review(github, pr_number, issues)

    record.update!(
      last_reviewed_sha: head_sha,
      initial_done: true,
      reviewed_at: Time.current,
      outcome: issues.any? ? "comments" : "looks_good",
      comment_count: issues.size
    )
  end

  private

  # Undo the claim made by PrReviewCheckJob when a review can't complete, so the
  # PR is retried next cycle. An initial claim (no prior review) is deleted
  # entirely; a followup claim keeps the existing review but clears the
  # in-flight SHA so the new commits are re-detected.
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
      return nil if cli_failed?(response)
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
    base = workspace.pr_review_prompt.presence || DEFAULT_PROMPT

    <<~PROMPT
      #{base}

      #{ticket}

      Changed files and diffs:
      #{diff}

      Return ONLY a JSON array of AT MOST #{cap} items (fewer is better; an empty
      array is a perfectly good result when the PR is sound):
      {"path": "<file>", "line": <line number in the new file>,
       "comment": "<the problem + fix, terse, 1–2 sentences>"}.
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
