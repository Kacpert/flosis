# Writes AI runs for ClaudeCliService (SCRUM-70): a "running" row as the CLI
# starts, its tokens now and then while it streams, and the finished row with
# its cost and price when it ends. Recording must never break or stop a run, so
# every method reports its own errors and returns nil.
module AiRun::Recorder
  # How often a streamed run's partial tokens are saved on its running row.
  PROGRESS_EVERY = 30.seconds

  module_function

  def start!(attribution, own_key:)
    a = attribution
    AiRun.create!(workspace: a.workspace, project: a.project, project_name: a.project&.name, area: a.area,
                  item: a.item, item_label: a.item_label, started_by: a.started_by, automation: a.automation,
                  own_key: own_key, status: "running", ran_at: Time.current)
  rescue StandardError => e
    report(e)
  end

  def progress!(run, usage)
    return unless run && usage.any?
    return if run.updated_at && run.updated_at > PROGRESS_EVERY.ago

    run.update_columns(usage.totals.slice(*token_columns).merge(updated_at: Time.current))
  rescue StandardError => e
    report(e)
  end

  # The price is the reported cost plus the margin that stands today: the
  # organization's plan's, or the default without one. An own-key run carries
  # no margin and is priced at its cost; an unknown cost leaves the price
  # unknown too.
  def finish!(run, usage, status:, duration_ms:)
    return unless run

    totals = own_share(usage.totals, run, streamed_output: usage.streamed_output_tokens)
    workspace = Workspace.includes(:ai_plan).find(run.workspace_id)
    margin = run.own_key ? nil : (workspace.ai_plan&.margin_percent || AiRun.default_margin_percent)
    cost = totals[:cost_usd]
    price = cost && (margin ? (cost * (1 + margin / 100)).round(6) : cost)
    run.update!(totals.slice(*token_columns, :model, :model_usage, :claude_session_id)
                      .merge(status: status, duration_ms: duration_ms, cost_usd: cost, margin_percent: margin, price_usd: price))
    AiMonthLimit.ensure_current!(workspace)
    AiModel.register!(totals[:model])
    run
  rescue StandardError => e
    report(e)
  end

  # A resumed Claude session reports the whole session so far, not the run
  # (Kacper, 2026-11-23: a thread's design turn was counted again with every
  # later message). A run of one records its report less the session's last
  # report. A report no larger than the output the run itself streamed, or
  # smaller in any part than the last report, is the run's own. The report
  # itself is kept as it came (model_usage), for the next run.
  def own_share(totals, run, streamed_output: nil)
    return totals if totals[:claude_session_id].blank?
    return totals if streamed_output && totals[:output_tokens].to_i <= streamed_output

    previous = AiRun.where(claude_session_id: totals[:claude_session_id]).where.not(id: run.id).where.not(model_usage: nil)
                    .where(ran_at: ..run.ran_at).order(:ran_at, :id).last
    share = previous && added(report_sums(totals[:model_usage]), report_sums(previous.model_usage))
    return totals unless share

    totals.merge(share.slice(*token_columns), cost_usd: totals[:cost_usd] && share[:cost_usd])
  end

  # Gives each run of a resumed session recorded before own_share its own
  # share, from the reports kept as they came, priced with the margin it was
  # priced with. Returns how many runs changed.
  def recount_sessions!
    sessions = AiRun.where.not(claude_session_id: [ nil, "" ]).where.not(model_usage: nil)
                    .group(:claude_session_id).having("COUNT(*) > 1").pluck(:claude_session_id)
    sessions.sum do |session|
      previous = nil
      AiRun.where(claude_session_id: session).where.not(model_usage: nil).order(:ran_at, :id).count do |run|
        report = report_sums(run.model_usage)
        share = previous && added(report, previous)
        previous = report
        next false unless share

        cost = run.cost_usd && share[:cost_usd]
        price = cost && (run.margin_percent ? (cost * (1 + run.margin_percent / 100)).round(6) : cost)
        counted = share.slice(*token_columns).merge(cost_usd: cost, price_usd: price)
        next false if counted.all? { |column, value| run[column] == value }

        run.update_columns(counted)
      end
    end
  end

  # A CLI report's totals (its modelUsage, by model), as the run's columns
  # name them; nil when there is none.
  def report_sums(model_usage)
    rows = model_usage.is_a?(Hash) ? model_usage.values.grep(Hash) : []
    return if rows.empty?

    { input_tokens: rows.sum { |row| row["inputTokens"].to_i },
      output_tokens: rows.sum { |row| row["outputTokens"].to_i },
      cache_write_tokens: rows.sum { |row| row["cacheCreationInputTokens"].to_i },
      cache_read_tokens: rows.sum { |row| row["cacheReadInputTokens"].to_i },
      cost_usd: rows.sum { |row| BigDecimal(row["costUSD"].to_s.presence || "0") } }
  end

  # What a report added to the one before it, or nil when it is smaller in
  # any part (then it is not the session's whole report). Its cost is kept to
  # the places the column keeps, so a recount compares like with like.
  def added(report, before)
    return unless report && before

    share = report.to_h { |column, value| [ column, value - before[column] ] }
    share.merge(cost_usd: share[:cost_usd].round(6)) unless share.values.any?(&:negative?)
  end

  def token_columns
    %i[input_tokens output_tokens cache_write_tokens cache_read_tokens]
  end

  def report(error)
    Rails.error.report(error, handled: true, context: { recorder: "AiRun::Recorder" })
    nil
  end
end
