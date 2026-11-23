# What a succeeded charge buys (SCRUM-71). A plan charge activates the plan and
# sets the month's limit to what was paid (the prorated first month included);
# an upgrade switches the plan now and adds its difference to the limit; a
# top-up adds to the balance (Ledger reads it from the charge) and lets a pause
# be announced again.
module Billing
  module Effects
    module_function

    def apply!(charge, account)
      case charge.kind
      when "plan"
        unless account.plan_running?
          account.update!(plan_state: "active", plan_started_on: charge.period_from, plan_ends_on: nil)
        end
        AiMonthLimit.paid!(charge.workspace, month: charge.period_month, plan: charge.ai_plan || charge.workspace.ai_plan,
                           limit_usd: charge.net_usd, starts_on: charge.period_from)
      when "upgrade"
        charge.workspace.update!(ai_plan: charge.ai_plan, ai_plan_assigned_at: Time.current)
        account.update!(pending_ai_plan: nil)
        AiMonthLimit.paid!(charge.workspace, month: charge.period_month, plan: charge.ai_plan,
                           limit_usd: charge.net_usd, add: true)
      when "top_up", "auto_top_up"
        account.update!(paused_notified_at: nil)
      end
    end
  end
end
