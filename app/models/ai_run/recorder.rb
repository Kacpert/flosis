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

    totals = usage.totals
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

  def token_columns
    %i[input_tokens output_tokens cache_write_tokens cache_read_tokens]
  end

  def report(error)
    Rails.error.report(error, handled: true, context: { recorder: "AiRun::Recorder" })
    nil
  end
end
