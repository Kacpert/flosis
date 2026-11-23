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
      charger = Charger.new(@workspace)
      charge = @account.with_lock do
        next nil unless due?

        charger.prepare!(kind: "auto_top_up", net: @account.auto_top_up_usd)
      end
      charge && charger.attempt!(charge, off_session: true)
    end

    # The automatic top-up would be charged now.
    def due?
      @account.auto_top_up && @account.plan_running? && @account.card? &&
        automatic_this_month < AUTO_TOP_UPS_PER_MONTH &&
        Ledger.balance(@workspace) <= 0 && limit_reached? && !held_back?
    end

    def automatic_this_month
      Ledger.automatic_top_ups(@workspace)
    end

    def paused_until_next_month?
      @account.auto_top_up && automatic_this_month >= AUTO_TOP_UPS_PER_MONTH
    end

    private

    def limit_reached?
      limit = AiMonthLimit.for(@workspace, Date.current)&.limit_usd
      limit.present? && Ledger.plan_spend(@workspace) >= limit
    end

    # One is being charged right now; or the last one failed and nobody has
    # acted since: AI stays paused until the card is changed or a top-up is
    # bought by hand, rather than every finished run trying the card again.
    def held_back?
      last = @workspace.billing_charges.automatic_top_ups.where(created_at: Date.current.in_time_zone.all_month).order(:id).last
      return false if last.nil? || last.succeeded?
      return last.created_at > 5.minutes.ago unless last.failed?

      acted = [ @account.card_saved_at, @workspace.billing_charges.top_ups.succeeded.maximum(:succeeded_at) ].compact.max
      acted.nil? || acted < last.created_at
    end
  end
end
