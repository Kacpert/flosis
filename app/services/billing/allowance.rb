# Whether an organization's AI may start a new run (SCRUM-71). Paused when:
# - no_plan: no paid plan runs (none, not activated yet, ended), unless Flosis
#   staff turned on free AI for the organization (workspaces.free_ai);
# - limit: this month's plan spend reached what was paid and the top-up
#   balance is empty (automatic top-up, if on, refills it first);
# - retry_spent: this month's plan charge failed and AI already used the 15%
#   of the plan price allowed while it is retried;
# - unpaid: the charge is still unpaid after the 7 days of retries.
# A run already going always finishes; Time & HR and runs on a project's own
# Anthropic key never pause.
module Billing
  class Allowance
    attr_reader :workspace, :reason, :plan_spend, :limit_usd, :charge, :today

    def self.for(workspace, today: Date.current)
      new(workspace, today)
    end

    # The gate ClaudeCliService asks before every run.
    def self.paused_for?(workspace, own_key: false)
      return false if own_key || workspace.nil?

      self.for(workspace).paused?
    end

    # Why, for ClaudeCliService::PausedError: nil when open.
    def self.reason_for(workspace, own_key: false)
      return nil if own_key || workspace.nil?

      self.for(workspace).reason
    end

    def initialize(workspace, today)
      @workspace = workspace
      @today = today
      @account = workspace.billing_account
      compute
    end

    def running?
      @account&.plan_running? || false
    end

    def paused?
      reason.present?
    end

    def payment_failing?
      charge&.failed? || false
    end

    def grace_usd
      charge&.grace_usd
    end

    def balance
      @balance ||= Ledger.balance(workspace)
    end

    def percent_used
      return nil unless limit_usd&.positive?

      (plan_spend / limit_usd * 100).round
    end

    # Past 80% of the limit but not at it: the amber banner.
    def near_limit?
      !paused? && !payment_failing? && limit_usd&.positive? && plan_spend >= limit_usd * BigDecimal("0.8") && plan_spend < limit_usd
    end

    def limit_reached?
      limit_usd.present? && plan_spend >= limit_usd
    end

    def auto_top_ups_paused?
      reason == :limit && @account.auto_top_up && Ledger.automatic_top_ups(workspace, today) >= AUTO_TOP_UPS_PER_MONTH
    end

    # When AI comes back on its own: the 1st, with the new month.
    def back_on
      today.next_month.beginning_of_month
    end

    private

    def compute
      @plan_spend = BigDecimal("0")
      unless running?
        @reason = :no_plan unless workspace.free_ai
        return
      end

      @plan_spend = Ledger.plan_spend(workspace, today)
      @charge = workspace.billing_charges.plan_charges.for_month(today).where.not(status: "abandoned").order(:id).last
      if payment_failing?
        @reason = if charge.unpaid?(today) then :unpaid
                  elsif plan_spend >= grace_usd then :retry_spent
                  end
        return
      end

      @limit_usd = AiMonthLimit.for(workspace, today)&.limit_usd
      @reason = :limit if limit_reached? && balance <= 0
    end
  end
end
