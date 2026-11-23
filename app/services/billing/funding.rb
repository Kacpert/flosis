# Who pays for a finished run (SCRUM-71), written on the run as funding:
# plan (counts toward the month's limit), top_up (past the limit, paid from
# the balance at cost + 30% instead of the plan's margin), free (no running
# plan) or legacy (ran before billing started; set by the migration). An
# own-key run, or one whose cost is unknown, is funded by nobody until staff
# set its cost. After a run is funded the admins may be told (80%, paused),
# and an automatic top-up may be due.
module Billing
  module Funding
    module_function

    def assign!(run)
      return if run.nil? || run.own_key || run.status == "running" || run.cost_usd.nil? || run.funding.present?

      workspace = run.workspace
      month = run.ran_at.in_time_zone.to_date
      if !workspace.billing_account&.plan_running?
        run.update_columns(funding: "free")
        return
      end

      if within_plan?(workspace, month)
        run.update_columns(funding: "plan")
      else
        price = (run.cost_usd * (1 + TOP_UP_MARGIN_PERCENT / 100)).round(6)
        run.update_columns(funding: "top_up", margin_percent: TOP_UP_MARGIN_PERCENT, price_usd: price)
      end
      after_run(workspace)
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { funding: "Billing::Funding.assign!", ai_run_id: run&.id })
    end

    # Under the limit before this run, or a failing payment's month (the grace
    # is the plan's, not the balance's).
    def within_plan?(workspace, month)
      charge = workspace.billing_charges.plan_charges.for_month(month).where.not(status: "abandoned").order(:id).last
      return true if charge&.failed?

      limit = AiMonthLimit.for(workspace, month)&.limit_usd
      limit.nil? || Ledger.plan_spend(workspace, month) < limit
    end

    def after_run(workspace)
      Billing::AutoTopUpJob.perform_later(workspace) if workspace.billing_account.auto_top_up
      Notices.after_run(workspace) if defined?(Notices)
    end
  end
end
