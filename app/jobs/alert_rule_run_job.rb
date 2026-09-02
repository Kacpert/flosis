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

    persist_ai_state(rule, response)

    # Notifications are opt-in: post only when the rule has notifications ON and
    # the AI decided the condition fired.
    notify_discord(rule, parsed) if parsed[:fired] && rule.notify_enabled? && rule.discord_webhook

    rule.update!(last_run_at: Time.current)
    run
  end

  # Save the AI-managed blobs it returned: its updated memory and any problems it
  # reported. Absent blocks leave the existing value untouched (the AI just
  # didn't change it this run); an explicitly empty block clears it.
  def persist_ai_state(rule, response)
    mem = extract_block(response, "memory")
    rule.store_memory(mem) unless mem.nil?

    issues = extract_block(response, "issues")
    rule.store_ai_issues(issues) unless issues.nil?
  end

  # Pull the inner text of <tag>…</tag> from the response, or nil if not present.
  def extract_block(response, tag)
    m = response.match(/<#{tag}>(.*?)<\/#{tag}>/m)
    m && m[1].strip
  end

  private

  def record_error_run(rule, summary: "Run failed")
    rule.alert_runs.create!(fired: false, summary: summary, detail: nil, status: "error", ran_at: Time.current)
    rule.update!(last_run_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[AlertRuleRunJob] failed to record error run for rule #{rule.id}: #{e.message}")
  end

  def run_ai(rule)
    project = rule.project
    # DB is the source of truth: regenerate the project's .mcp.json right before
    # running so a deleted/stale file self-heals and creds are always current.
    ProjectMcpConfig.write!(project) if project.workspace_dir.present?

    prompt = build_prompt(rule)
    # Automations act on GitHub + Jira (scan PRs, post comments) via that
    # project's own MCP servers, and run inside its repo checkout. When the
    # project has no folder yet, mcp_config is nil and the codebase falls back
    # to the shared ~/work/elvium — i.e. the pre-feature behavior.
    service = ClaudeCliService.new(
      codebase_path: project.repo_checkout_path,
      allowed_tools: ClaudeCliService::AUTOMATION_TOOLS,
      mcp_config: (ProjectMcpConfig.path_for(project) if project.workspace_dir.present?)
    )
    service.start_session(prompt: prompt)[:response].to_s.tap do |response|
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
      You are an autonomous project automation. Carry out the INSTRUCTION below,
      then report back in the blocks described.

      # Instruction (what to do)

      #{rule.prompt}

      # Tools you can use

      You have live tools: read the checked-out codebase (Read/Grep/Glob), the web
      (WebFetch), and act on GitHub + Jira via MCP — list/read pull requests, read
      files, read commits, and read/POST Jira issue comments. Use them to actually
      do the work the instruction asks (e.g. scan a PR's diff, add a Jira comment).

      # Your memory (you manage it)

      This is YOUR persistent memory for this automation across runs — use it so
      you DON'T redo work you already did (e.g. which PR you scanned at which
      commit, which items you already reported/notified). Read it first, act only
      on what's NEW since last time, then return your UPDATED full memory.

      Only re-check things that actually changed (a new commit / force-push moves a
      PR's updated-at — skip PRs whose recorded state is unchanged). The memory can
      grow without bound, so PRUNE entries that are no longer relevant (closed PRs,
      old runs) to keep it lean. It has a hard 200KB cap — stay well under it.

      Current memory (JSON; empty on first run):
      #{rule.memory_text.presence || "{}"}

      # Notifications

      #{notification_instruction(rule)}

      #{recent_runs_section(rule)}
      # Board snapshot (read-only context; your tools give you the live details)

      #{board_snapshot(rule).to_json}

      # How to reply — EXACTLY these blocks

      1. <alert>{"fired": bool, "summary": "…", "detail": "…"}</alert>
         - fired=true ONLY when you should notify this run (per the notification
           rules above). summary ≤ 90 chars (internal history label). detail = the
           EXACT natural message to post (no title/header — reads like a person).
         - fired=false when there's nothing new to notify.
      2. <memory>{…your full updated memory as JSON…}</memory> — ALWAYS include it.
      3. <issues>…plain text…</issues> — ONLY if you hit a real problem doing the
         work (no permission to comment, an expired/invalid key/token, an API
         error, a missing config). Describe what failed and where, so an operator
         can fix it. Omit this block entirely when everything worked.
    PROMPT
  end

  # Tell the AI whether/when to notify, based on the rule's opt-in switch.
  def notification_instruction(rule)
    if rule.notify_enabled? && rule.discord_webhook
      "Notifications are ON (channel: #{rule.discord_webhook.channel_name}). Set " \
      "fired=true and write the message in `detail` ONLY when the instruction's " \
      "condition to notify is met (e.g. first time, or genuinely new items) — not " \
      "on every run."
    else
      "Notifications are OFF for this automation. Do the work and update your " \
      "memory/issues, but ALWAYS set fired=false — do not write a notification."
    end
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
  # A column's name and the status behind it are NOT the same thing, and a rule
  # is written the way a person reads the board. On this project the DEV board's
  # "Customer Acceptance" column holds the status "Pre-production", while the
  # status literally named "Customer Acceptance" belongs to the Design board — so
  # a snapshot carrying statuses alone made an automation asked for one board's
  # column silently work on the other's tickets. Each task therefore says which
  # column it sits in ON WHICH BOARD, and the board layout ships with it.
  def board_snapshot(rule)
    now = Time.current
    project = rule.project
    boards = project.jira_boards
                   .includes(:jira_sprints, jira_board_columns: :jira_board_column_statuses)
                   .order(:name).to_a
    columns_by_status = column_index(boards)
    sprint_states = sprint_states_for(boards)
    tasks = project.tasks.jira_synced.order(:jira_updated_at).to_a
    tasks_by_sprint = tasks.group_by(&:sprint_id)

    {
      project: project.name,
      generated_at: now.iso8601,
      note: "A board COLUMN and a Jira STATUS are different names for different things — "             "match a rule that talks about a column against each task's `columns` map, not its `status`. "             "`columns` gives the column this task sits in on each board it appears on; a board is absent "             "when its layout maps no column to that status. Every synced task is listed, including ones "             "outside the active sprint — use `sprint` / `sprint_state` when a rule is about a sprint. " \
            "Each board also lists its open `sprints` with totals, including one holding no tickets, so " \
            "\"does the next sprint exist and is it filled?\" is answerable here. points_total sums " \
            "ai_estimate_points — this team leaves Jira's story-point fields empty, so the AI estimate " \
            "is the only number available; unestimated_tasks says how many carry no number at all. "             "days_in_status is an approximation: time since jira_updated_at (last Jira update), not a true per-status timer.",
      boards: boards.map do |board|
        {
          name: board.name,
          columns: board.jira_board_columns.sort_by { |c| c.position.to_i }.map do |column|
            { name: column.name, statuses: column.status_names }
          end,
          sprints: sprint_rows(board, tasks_by_sprint)
        }
      end,
      tasks: tasks.map do |t|
        {
          key: t.external_reference,
          title: t.name,
          status: t.jira_status_name,
          columns: columns_by_status[t.jira_status_name] || {},
          assignee: t.assignee_name || t.assignee_email,
          issue_type: t.issue_type,
          sprint: t.sprint_name,
          sprint_state: sprint_states[t.sprint_id],
          story_points: t.story_points,
          ai_estimate_points: t.ai_estimate_points,
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

  # status name => { board name => column name }. Built once per run rather than
  # per task: a project has a couple of boards and hundreds of tickets.
  def column_index(boards)
    boards.each_with_object(Hash.new { |h, k| h[k] = {} }) do |board, index|
      board.jira_board_columns.each do |column|
        column.status_names.each { |status| index[status][board.name] = column.name }
      end
    end
  end

  # Every open sprint on the board, WITH ITS TOTALS — including one that holds
  # no tickets at all. A rule that asks "is the next sprint filled?" has to be
  # able to see an empty sprint, and a snapshot that mentions sprints only via
  # the tasks assigned to them makes exactly that case invisible.
  #
  # points_total sums ai_estimate_points, not story_points: this team leaves
  # Jira's story-point fields empty (0 of 386 tickets carry one), so the AI
  # estimate is the only number there is. unestimated_tasks travels with it, so
  # a partial total is never mistaken for a complete one.
  def sprint_rows(board, tasks_by_sprint)
    board.jira_sprints.select { |s| %w[active future].include?(s.state) }
         .sort_by { |s| [ s.state == "active" ? 0 : 1, s.start_date || Time.zone.at(0) ] }
         .map do |sprint|
      sprint_tasks = tasks_by_sprint[sprint.jira_sprint_id] || []
      estimated = sprint_tasks.filter_map(&:ai_estimate_points)

      {
        name: sprint.name,
        state: sprint.state,
        starts_at: sprint.start_date&.to_date&.iso8601,
        ends_at: sprint.end_date&.to_date&.iso8601,
        task_count: sprint_tasks.size,
        points_total: estimated.sum.to_f.round(1),
        estimated_tasks: estimated.size,
        unestimated_tasks: sprint_tasks.size - estimated.size
      }
    end
  end

  # Jira sprint id => "active" / "future". Closed sprints are left out: a task
  # still pointing at one is not in a sprint that matters.
  def sprint_states_for(boards)
    JiraSprint.where(jira_board_id: boards.map(&:id), state: %w[active future])
              .pluck(:jira_sprint_id, :state).to_h
  end
end
