# Runs a single AlertRule: builds a JSON snapshot of the live Jira board (no
# MCP — plain ActiveRecord reads of data JiraSyncService already keeps fresh),
# asks the Claude CLI to evaluate the rule's natural-language prompt against
# it, and records an AlertRun. If the AI says the condition fired, posts a
# Discord notification via DiscordWebhookClient (which itself never raises).
#
# Follows the same CLI-failure-marker convention as PrReviewJob/AutoEstimateJob:
# the Claude CLI sometimes prints auth/quota/transport failures as plain text
# instead of raising, so those must not be mistaken for a real "not fired"
# verdict. A genuine CLI failure (raised ClaudeCliError) OR a
# marker/too-short response records AlertRun(status: "error") and returns —
# it must never crash the job (a bad rule/prompt must not take down the
# scheduler for every other rule).
class AlertRuleRunJob < ApplicationJob
  queue_as :default

  CODEBASE_PATH = ENV.fetch("PR_REVIEW_CODEBASE_PATH", File.expand_path("~/work/elvium"))

  CLI_FAILURE_MARKERS = /\b(401|403|429|invalid authentication|failed to authenticate|api error|credit balance|rate limit|usage limit|overloaded|unauthorized)\b/i

  def perform(alert_rule_id)
    rule = AlertRule.find_by(id: alert_rule_id)
    return unless rule

    response = run_ai(rule)

    if response.nil?
      record_error_run(rule)
      return
    end

    parsed = AlertParser.extract(response)
    if parsed.nil?
      record_error_run(rule, summary: "Run failed")
      return
    end

    run = rule.alert_runs.create!(
      fired: parsed[:fired],
      summary: parsed[:summary],
      detail: parsed[:detail],
      status: "ok",
      ran_at: Time.current
    )

    notify_discord(rule, parsed) if parsed[:fired]

    rule.update!(last_run_at: Time.current)
    run
  end

  private

  def record_error_run(rule, summary: "Run failed")
    rule.alert_runs.create!(fired: false, summary: summary, detail: nil, status: "error", ran_at: Time.current)
    rule.update!(last_run_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[AlertRuleRunJob] failed to record error run for rule #{rule.id}: #{e.message}")
  end

  def run_ai(rule)
    prompt = build_prompt(rule)
    ClaudeCliService.new(codebase_path: CODEBASE_PATH).start_session(prompt: prompt)[:response].to_s.tap do |response|
      return nil if cli_failed?(response)
    end
  rescue ClaudeCliService::ClaudeCliError => e
    Rails.logger.error("[AlertRuleRunJob] claude error: #{e.message}")
    nil
  end

  def cli_failed?(response)
    response.match?(CLI_FAILURE_MARKERS) || response.strip.length < 20
  end

  def notify_discord(rule, parsed)
    # Post ONLY the AI's natural message — no 🔔/rule-name/summary header — so it
    # reads like a real person wrote it, not a system notification. The
    # summary/rule name are still kept on the AlertRun for the history view.
    content = parsed[:detail].presence || parsed[:summary]
    return if content.blank?

    DiscordWebhookClient.post(rule.discord_webhook.url, content: content)
  end

  def build_prompt(rule)
    <<~PROMPT
      You are a delivery-watchdog. Evaluate the condition below against the JSON
      snapshot. Reply with exactly one
      <alert>{"fired": bool, "summary": "…", "detail": "…"}</alert>. summary ≤ 90 chars.

      Condition:
      #{rule.prompt}
      #{recent_runs_section(rule)}
      Board snapshot (JSON):
      #{board_snapshot(rule).to_json}
    PROMPT
  end

  # The last ~20 runs of THIS rule, so the AI can write a message that fits the
  # cadence and — crucially for "vary the message each time" style rules — does
  # NOT repeat what it already said. We show the actual posted summary/detail of
  # fired runs (and note the quiet ones) newest-first.
  def recent_runs_section(rule)
    runs = rule.alert_runs.newest_first.limit(20).to_a
    return "" if runs.empty?

    lines = runs.map do |r|
      when_at = r.ran_at&.strftime("%Y-%m-%d %H:%M") || "?"
      if r.fired
        "- #{when_at} — FIRED · #{r.summary}#{r.detail.present? ? " — #{r.detail}" : ''}"
      else
        "- #{when_at} — quiet (condition not met)"
      end
    end

    <<~SECTION

      Your recent history for THIS rule (newest first — the FIRED lines are the
      messages you already posted). Do NOT repeat previous wording; keep it fresh
      and varied, and stay consistent with the cadence/tone the condition asks for:
      #{lines.join("\n")}
    SECTION
  end

  # No MCP — a plain snapshot built from data already synced locally
  # (JiraSyncService keeps tasks fresh). `days_in_status` is an APPROXIMATION:
  # `now - jira_updated_at`, i.e. time since the ticket was last updated in
  # Jira at all, not strictly time since its last status transition (Jira
  # doesn't expose per-status timestamps to us) — documented here so the AI
  # (and future readers) don't over-trust its precision.
  def board_snapshot(rule)
    now = Time.current
    tasks = rule.project.tasks.jira_synced.order(:jira_updated_at)

    {
      project: rule.project.name,
      generated_at: now.iso8601,
      note: "days_in_status is an approximation: time since jira_updated_at (last Jira update), not a true per-status timer.",
      tasks: tasks.map do |t|
        {
          key: t.external_reference,
          title: t.name,
          status: t.jira_status_name,
          assignee: t.assignee_name || t.assignee_email,
          issue_type: t.issue_type,
          sprint: t.sprint_name,
          days_in_status: t.jira_updated_at ? ((now - t.jira_updated_at) / 1.day).round(1) : nil
        }
      end,
      open_prs: rule.workspace.pr_reviews.map do |pr|
        {
          number: pr.pr_number,
          title: pr.pr_title,
          branch: pr.pr_branch,
          author: pr.pr_author,
          outcome: pr.outcome,
          reviewed_at: pr.reviewed_at&.iso8601
        }
      end
    }
  end
end
