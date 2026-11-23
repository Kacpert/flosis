# Choosing, activating, changing and cancelling an organization's plan
# (SCRUM-71). A plan starts once billing details and a card are there: the days
# left this month are charged now and are the month's limit. A higher plan
# starts now (the difference for the days left is charged and added to the
# limit); a lower one starts on the 1st. Cancelling keeps the paid month and
# charges nothing after.
module Billing
  class Plans
    # kind: :current · :now (activation or upgrade, charged today) · :next_month
    Preview = Data.define(:plan, :kind, :net, :limit_after, :period, :summary)

    attr_reader :workspace, :account

    def initialize(workspace, user: nil, today: Date.current)
      @workspace = workspace
      @account = workspace.billing
      @user = user
      @today = today
    end

    def options
      AiPlan.order(:monthly_price_usd, :name)
    end

    def preview(plan)
      current = workspace.ai_plan
      period = Proration.period(@today)
      days = Proration.label(period)
      if account.plan_running? && plan == current
        pending = account.pending_ai_plan
        summary = pending ? "#{plan.name} stays your plan: #{pending.name} won't start on #{next_first}." : "#{plan.name} is your plan. Nothing changes."
        Preview.new(plan: plan, kind: :current, net: 0, limit_after: nil, period: nil, summary: summary)
      elsif account.plan_running? && plan.monthly_price_usd > current.monthly_price_usd
        net = Proration.amount(plan.monthly_price_usd - current.monthly_price_usd, @today)
        limit = month_limit + net
        Preview.new(plan: plan, kind: :now, net: net, limit_after: limit, period: period,
                    summary: "#{plan.name} starts now: #{money(net)}#{plus_vat} is charged today for #{days}, and this month’s limit becomes #{money(limit)}.")
      elsif account.plan_running?
        Preview.new(plan: plan, kind: :next_month, net: 0, limit_after: nil, period: nil,
                    summary: "#{plan.name} starts on #{next_first}. This month stays on #{current.name}.")
      else
        net = Proration.amount(plan.monthly_price_usd, @today)
        summary = if account.ready?
          "#{plan.name} starts now: #{money(net)}#{plus_vat} is charged today for #{days}, and this month’s limit is #{money(net)}."
        else
          "#{plan.name} starts once billing details and a card are added: #{money(net)}#{plus_vat} for the days left this month."
        end
        Preview.new(plan: plan, kind: :now, net: net, limit_after: net, period: period, summary: summary)
      end
    end

    # Returns the charge when one was made (succeeded, failed or waiting for
    # 3-D Secure), nil when nothing was charged.
    def choose!(plan, return_url: nil)
      preview = preview(plan)
      case preview.kind
      when :current
        account.update!(pending_ai_plan: nil)
        nil
      when :next_month
        account.update!(pending_ai_plan: plan)
        nil
      when :now
        account.plan_running? ? upgrade!(plan, preview, return_url) : start!(plan, return_url)
      end
    end

    def activate!(return_url: nil)
      plan = workspace.ai_plan
      raise NotReady, "Choose a plan first" unless plan
      raise NotReady, "Add billing details and a card first" unless account.ready?
      return nil if account.plan_running?

      Charger.new(workspace).charge!(kind: "plan", net: Proration.amount(plan.monthly_price_usd, @today), plan: plan,
                                     period: Proration.period(@today), user: @user, off_session: false, return_url: return_url)
    end

    def cancel!
      raise NotReady, "There is no active plan to cancel" unless account.plan_state == "active"

      account.update!(plan_state: "cancelling", plan_ends_on: @today.end_of_month, pending_ai_plan: nil)
    end

    def keep!
      return unless account.cancelling?

      account.update!(plan_state: "active", plan_ends_on: nil)
    end

    # This month's plan charge failed and is being retried.
    def payment_failing?
      current_charge&.failed?
    end

    def current_charge
      workspace.billing_charges.plan_charges.for_month(@today).order(:id).last
    end

    def next_first
      @today.next_month.beginning_of_month.strftime("%-d %b %Y")
    end

    private

    def start!(plan, return_url)
      workspace.update!(ai_plan: plan, ai_plan_assigned_at: Time.current)
      account.update!(plan_state: "pending", pending_ai_plan: nil, plan_ends_on: nil)
      account.ready? ? activate!(return_url: return_url) : nil
    end

    def upgrade!(plan, preview, return_url)
      raise NotReady, "This month’s payment failed: change the card first." if payment_failing?

      Charger.new(workspace).charge!(kind: "upgrade", net: preview.net, plan: plan, period: preview.period,
                                     user: @user, off_session: false, return_url: return_url)
    end

    def month_limit
      AiMonthLimit.for(workspace, @today)&.limit_usd.to_d
    end

    def money(amount)
      AiCostFormatter.money(amount)
    end

    # " + VAT" for a buyer who pays Polish VAT (or hasn't said where they are yet).
    def plus_vat
      !account.details_complete? || account.vat.charged? ? " + VAT" : ""
    end
  end
end
