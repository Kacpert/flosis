# AI "forensic engineer" that determines a bug's likely origin by running
# git log/git blame/grep in the repo checkout via the Claude CLI, then
# attributes it to the most likely author.
#
# Signature: perform(project_id, jira_key) — NOT a task_id. A bug is
# analyzed while OPEN (a row in `tasks`), but once FIXED it only exists in
# `delivered_issues` (see DeliveredIssue's HR-BOUNDARY comment) — so the job
# is keyed the same way BugAttribution itself is keyed, and can run at any
# point in the bug's life. The bug's title/description are resolved by
# checking `tasks` FIRST (the bug is still open), falling back to
# `delivered_issues` (the bug has since been fixed and removed from tasks).
# If neither has a matching row, the job no-ops (nothing to analyze).
#
# Follows the same CLI-failure-marker convention as AutoEstimateJob /
# AlertRuleRunJob / PrReviewJob: the Claude CLI sometimes prints auth/quota/
# transport failures as plain text instead of raising, so those must not be
# mistaken for a real (if low-confidence) verdict. A genuine CLI failure
# (raised ClaudeCliError) OR a marker/too-short response OR an unparseable
# response all record BugAttribution(status: "failed") and return — never
# crash (retryable later by a manual "Analyze" button, per the brief).
#
# Idempotent: upserts the single BugAttribution row keyed by
# [project_id, jira_key] — re-running (e.g. a manual retry after a failure)
# updates the SAME row rather than creating a new one.
class BugAttributionJob < ApplicationJob
  queue_as :default

  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def perform(project_id, jira_key)
    project = Project.find_by(id: project_id)
    return unless project

    bug = resolve_bug(project, jira_key)
    return unless bug

    attribution = BugAttribution.find_or_initialize_by(project: project, jira_key: jira_key)
    attribution.task = bug[:task]

    response = run_ai(project, jira_key, bug)
    if response.nil?
      record_failure(attribution)
      return
    end

    parsed = AttributionParser.extract(response)
    if parsed.nil?
      record_failure(attribution)
      return
    end

    attribution.update!(
      origin_kind: parsed[:origin_kind],
      author_name: parsed[:author_name],
      author_email: parsed[:author_email],
      confidence: parsed[:confidence],
      reasoning: parsed[:reasoning],
      status: "done",
      analyzed_at: Time.current
    )
  end

  private

  # Looks up the bug's title/description from `tasks` (open) first, falling
  # back to `delivered_issues` (fixed). Returns nil if neither has it.
  def resolve_bug(project, jira_key)
    task = project.tasks.find_by(external_reference: jira_key)
    if task
      return { task: task, title: task.name, description: task.description.to_s, created_at: task.jira_created_at }
    end

    delivered = project.delivered_issues.find_by(jira_key: jira_key)
    return nil unless delivered

    { task: nil, title: delivered.title, description: "", created_at: delivered.jira_created_at }
  end

  def record_failure(attribution)
    attribution.status = "failed"
    attribution.save!
  end

  def run_ai(project, jira_key, bug)
    prompt = build_prompt(project, jira_key, bug)
    ClaudeCliService.new(codebase_path: CODEBASE_PATH).start_session(prompt: prompt)[:response].to_s.tap do |response|
      return nil if cli_failed?(response)
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[BugAttributionJob] claude error: #{e.message}")
    nil
  end

  def cli_failed?(response)
    response.match?(CLI_FAILURE_MARKERS) || response.strip.length < 20
  end

  def build_prompt(project, jira_key, bug)
    ticket = <<~TICKET
      Bug #{jira_key}: #{bug[:title]}
      #{bug[:description]}
      Reported: #{bug[:created_at]&.iso8601 || "unknown"}
    TICKET

    context_parts = [ticket]
    if project.features_summary.present?
      context_parts << "Codebase feature summary:\n#{project.features_summary}"
    end

    <<~PROMPT
      You are a forensic engineer investigating the origin of a bug. The
      repository is checked out in your current working directory — use
      `git log`, `git blame`, and `grep` to locate the commit(s) and file(s)
      that introduced the defect described below. Do not guess without
      looking; ground your answer in what you actually find in the repo.

      #{context_parts.join("\n\n")}

      Decide:
      - origin_kind: "new_functionality" if the defect was introduced by a
        recent feature/change, or "existing_code" if it's in long-standing
        code that predates any recent related change.
      - The most likely author (name + email) who introduced the defect,
        from git blame/log authorship.
      - confidence: "high", "medium", or "low".
      - A 1-3 sentence reasoning that CITES specific commits and/or files you
        found.

      Reply with exactly one block:
      <attribution>{"origin_kind": "new_functionality"|"existing_code", "author_name": "…", "author_email": "…", "confidence": "high"|"medium"|"low", "reasoning": "…"}</attribution>
    PROMPT
  end
end
