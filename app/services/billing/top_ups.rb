# Top-ups (SCRUM-71): money for after the monthly limit, $100, $200 or $300,
# charged straight away. Bought by hand, or automatically when the limit is
# reached and the balance runs out: at most 3 automatic ones a calendar month.
# They never expire, carry over, and are never refunded.
module Billing
  class TopUps
    def initialize(workspace, user: nil)
      @workspace = workspace
      @account = workspace.billing
      @user = user
    end

    def buy!(amount, return_url: nil)
      amount = BigDecimal(amount.to_s)
      raise NotReady, "Choose an amount: $100, $200 or $300" unless TOP_UP_AMOUNTS.include?(amount)
      raise NotReady, "Available once the plan is active" unless @account.plan_running?

      Charger.new(@workspace).charge!(kind: "top_up", net: amount, user: @user, off_session: false, return_url: return_url)
    end

    def configure!(enabled:, amount:)
      amount = BigDecimal(amount.to_s)
      raise NotReady, "Choose an amount: $100, $200 or $300" unless TOP_UP_AMOUNTS.include?(amount)

      @account.update!(auto_top_up: enabled, auto_top_up_usd: amount)
    end

    # Charges the automatic top-up if it is due: the limit reached, the balance
    # gone, the switch on, fewer than 3 this month, and none in the last few
    # minutes. The account row is locked, so two runs finishing at once charge
    # once. Returns the charge, or nil.
    def auto!
      @account.with_lock do
        return nil unless due?

        Charger.new(@workspace).charge!(kind: "auto_top_up", net: @account.auto_top_up_usd, off_session: true)
      end
    end

    def automatic_this_month
      Ledger.automatic_top_ups(@workspace)
    end

    def paused_until_next_month?
      @account.auto_top_up && automatic_this_month >= AUTO_TOP_UPS_PER_MONTH
    end

    private

    def due?
      @account.auto_top_up && @account.plan_running? && @account.card? &&
        automatic_this_month < AUTO_TOP_UPS_PER_MONTH &&
        Ledger.balance(@workspace) <= 0 && limit_reached? && !recent_attempt?
    end

    def limit_reached?
      limit = AiMonthLimit.for(@workspace, Date.current)&.limit_usd
      limit.present? && Ledger.plan_spend(@workspace) >= limit
    end

    # A failed automatic top-up pauses AI until someone acts; it is not tried
    # again by every run that finishes after it.
    def recent_attempt?
      last = @workspace.billing_charges.automatic_top_ups.where(created_at: Date.current.in_time_zone.all_month).order(:id).last
      last.present? && (last.failed? || last.created_at > 5.minutes.ago) && !last.succeeded?
    end
  end
end
