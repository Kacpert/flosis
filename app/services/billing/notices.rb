# When the admins hear about billing by email (SCRUM-71), each at most as often
# as the designs say: a plan payment that failed at every attempt; an automatic
# top-up that failed; 80% of the month's limit once a month; AI paused at the
# limit with no balance once per pause (a top-up resets it); AI paused while a
# payment fails once per charge. Invoices are emailed by Ksef::SendInvoiceJob.
module Billing
  module Notices
    module_function

    def charge_failed(charge, first_attempt:)
      account = charge.workspace.billing_account
      case charge.kind
      when "plan" then BillingMailer.payment_failed(charge).deliver_later if account&.plan_running?
      when "auto_top_up" then BillingMailer.auto_top_up_failed(charge).deliver_later
      end
    end

    # After a run was funded: the 80% email, or a pause announced.
    def after_run(workspace)
      account = workspace.billing_account
      return unless account&.plan_running?

      allowance = Allowance.for(workspace)
      month = Date.current.beginning_of_month
      if allowance.limit_usd&.positive? && !allowance.payment_failing? &&
         allowance.plan_spend >= allowance.limit_usd * BigDecimal("0.8") && account.usage_80_notified_on != month
        account.update_columns(usage_80_notified_on: month)
        BillingMailer.usage_80(workspace).deliver_later
      end

      case allowance.reason
      when :limit
        return if auto_top_up_coming?(workspace, account)
        return if account.paused_notified_at && account.paused_notified_at >= month.in_time_zone

        account.update_columns(paused_notified_at: Time.current)
        BillingMailer.limit_reached(workspace).deliver_later
      when :retry_spent
        charge = allowance.charge
        return if charge.paused_notified_at

        charge.update_columns(paused_notified_at: Time.current)
        BillingMailer.payment_paused(charge).deliver_later
      end
    end

    def auto_top_up_coming?(workspace, account)
      account.auto_top_up && account.card? && Ledger.automatic_top_ups(workspace) < AUTO_TOP_UPS_PER_MONTH &&
        !workspace.billing_charges.automatic_top_ups.failed.where(created_at: Date.current.in_time_zone.all_month).exists?
    end
  end
end
