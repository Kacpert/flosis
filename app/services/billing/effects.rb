# What a succeeded charge buys (SCRUM-71). A plan charge activates the plan and
# sets the month's limit to what was paid (the prorated first month included);
# an upgrade switches the plan now and adds its difference to the limit; a
# top-up adds to the balance (Ledger reads it from the charge) and lets a pause
# be announced again. A plan month paid after its payment had failed takes
# back from the top-up balance what it paid meanwhile (Kacper, 2026-11-24:
# the top-up is a buffer while the payment fails, returned once it is paid).
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
        give_back_top_up!(charge) if charge.first_failed_at
      when "upgrade"
        charge.workspace.update!(ai_plan: charge.ai_plan, ai_plan_assigned_at: Time.current)
        account.update!(pending_ai_plan: nil)
        AiMonthLimit.paid!(charge.workspace, month: charge.period_month, plan: charge.ai_plan,
                           limit_usd: charge.net_usd, add: true)
      when "top_up", "auto_top_up"
        account.update!(paused_notified_at: nil)
      end
    end

    # The month's runs the top-up paid before the month was paid become the
    # plan's, at the plan's margin, oldest first while the paid limit has
    # room; the balance gets their price back.
    def give_back_top_up!(charge)
      workspace = charge.workspace
      month = charge.period_month
      margin = (charge.ai_plan || workspace.ai_plan)&.margin_percent || AiRun.default_margin_percent
      room = AiMonthLimit.for(workspace, month).limit_usd.to_d - Ledger.plan_spend(workspace, month)
      AiRun.where(workspace_id: workspace.id, funding: "top_up").finished.in_month(month)
           .where(ran_at: ...charge.succeeded_at).order(:ran_at, :id).each do |run|
        price = (run.cost_usd * (1 + margin / 100)).round(6)
        break if price > room

        run.update_columns(funding: "plan", margin_percent: margin, price_usd: price)
        room -= price
      end
    end
  end
end
