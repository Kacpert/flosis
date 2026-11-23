# A run that came back with no cost stays flagged to Flosis staff until
# somebody has looked at it (SCRUM-70). It is never counted as $0 either way.
class Hidmin::AiRunsController < Hidmin::BaseController
  def looked_at
    run = AiRun.find(params[:id])
    run.update!(unknown_reviewed_at: Time.current, unknown_reviewed_by: current_user)
    redirect_to hidmin_workspace_path(run.workspace_id), flash: { clar_toast: "Marked as looked at" }
  end

  # SCRUM-71: staff set what an unknown-cost run cost; only then does it count
  # toward the organization's limit or balance (never a run from before
  # billing started), priced at the plan's margin as the day it ran.
  def set_cost
    run = AiRun.find(params[:id])
    cost = BigDecimal(params[:cost_usd].to_s)
    raise ArgumentError if cost.negative?

    margin = run.own_key ? nil : (run.workspace.ai_plan&.margin_percent || AiRun.default_margin_percent)
    run.update!(cost_usd: cost, margin_percent: margin, price_usd: margin ? (cost * (1 + margin / 100)).round(6) : cost,
                unknown_reviewed_at: Time.current, unknown_reviewed_by: current_user)
    Billing::Funding.assign!(run)
    redirect_to hidmin_workspace_path(run.workspace_id), flash: { clar_toast: "Cost set: #{AiCostFormatter.money(cost)}" }
  rescue ArgumentError
    redirect_to hidmin_workspace_path(run.workspace_id), flash: { alert: "The cost must be a number of dollars, like 0.42" }
  end
end
