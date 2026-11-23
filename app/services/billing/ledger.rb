# What an organization's AI used against what it paid (SCRUM-71): the month's
# spend counted toward the plan's limit, what the top-up balance paid, and the
# balance left. Only runs funded after billing started count (ai_runs.funding):
# legacy and free runs are recorded and priced but never charged.
module Billing
  module Ledger
    module_function

    def plan_spend(workspace, month = Date.current)
      runs(workspace, month).where(funding: "plan").sum(:price_usd)
    end

    def top_up_spent(workspace, month = Date.current)
      runs(workspace, month).where(funding: "top_up").sum(:price_usd)
    end

    # Bought top-ups less what top-up runs cost. A run already going when the
    # balance ran out may take it a little below zero; the next top-up covers it.
    def balance(workspace)
      bought = workspace.billing_charges.top_ups.succeeded.sum(:net_usd)
      spent = AiRun.where(workspace_id: workspace.id, funding: "top_up").finished.sum(:price_usd)
      (bought - spent).round(2)
    end

    def automatic_top_ups(workspace, month = Date.current)
      workspace.billing_charges.automatic_top_ups.succeeded.charged_in_month(month).count
    end

    def runs(workspace, month)
      AiRun.where(workspace_id: workspace.id).finished.in_month(month)
    end
    private_class_method :runs
  end
end
