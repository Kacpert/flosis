# The 1st of the month, 06:00 Warsaw (SCRUM-71): every running plan is charged
# its full price upfront for the month. Before that, a plan cancelled last
# month ends (nothing charged), a downgrade chosen last month starts, and a
# charge last month never collected is abandoned (it was never invoiced). Safe
# to run twice: a month already charged is not charged again.
module Billing
  class MonthStartJob < ApplicationJob
    queue_as :default

    def perform(today = Date.current)
      BillingAccount.where(plan_state: %w[active cancelling]).includes(:workspace).find_each do |account|
        self.class.start!(account, today)
      rescue StandardError => e
        Rails.logger.error("[Billing::MonthStartJob] workspace #{account.workspace_id}: #{e.class}: #{e.message}")
        Rails.error.report(e, handled: true, context: { workspace_id: account.workspace_id })
      end
    end

    # One organization's month start. Also run on demand when an admin
    # changes the plan before 06:00 on the 1st, so the month is charged
    # before the change rather than twice after it.
    def self.start!(account, today = Date.current)
      workspace = account.workspace
      month = today.beginning_of_month
      workspace.billing_charges.where(status: %w[failed requires_action pending]).where(period_month: ...month).find_each do |old|
        old.failed? ? old.update!(status: "abandoned", next_retry_on: nil) : Billing::Stale.close!(old)
      end

      if account.cancelling?
        return if account.plan_ends_on && account.plan_ends_on >= today

        account.update!(plan_state: "ended", pending_ai_plan: nil)
        workspace.update!(ai_plan: nil)
        return
      end

      if account.pending_ai_plan
        workspace.update!(ai_plan: account.pending_ai_plan, ai_plan_assigned_at: Time.current)
        account.update!(pending_ai_plan: nil)
      end
      return if workspace.billing_charges.plan_charges.for_month(month).where.not(status: "abandoned").exists?

      plan = workspace.ai_plan
      Charger.new(workspace).charge!(kind: "plan", net: plan.monthly_price_usd, plan: plan, period: month..month.end_of_month)
    end

    # Whether this month has not been charged yet (the job runs at 06:00).
    def self.due?(account, today = Date.current)
      account.plan_running? &&
        !account.workspace.billing_charges.plan_charges.for_month(today).where.not(status: "abandoned").exists?
    end
  end
end
