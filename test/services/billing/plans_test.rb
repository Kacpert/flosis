require "test_helper"

class Billing::PlansTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @team = billing_plan(name: "Team", price: 300)
    @growth = billing_plan(name: "Growth", price: 600)
    @starter = billing_plan(name: "Starter", price: 200)
  end

  def plans(on)
    Billing::Plans.new(@workspace.reload, user: users(:one), today: on)
  end

  test "joining on 20 Nov with a $300 plan charges $110 and sets a $110 limit" do
    billing_ready!(@workspace)
    travel_to Time.zone.local(2026, 11, 20, 10) do
      charge = plans(Date.current).choose!(@team, return_url: "https://app/return")
      assert charge.succeeded?
      assert_equal BigDecimal("110"), charge.net_usd
      assert_equal BigDecimal("25.30"), charge.vat_usd
      assert_equal 13530, @billing_gateway.charges.last[:cents]
      assert_not @billing_gateway.charges.last[:off_session]
      limit = AiMonthLimit.for(@workspace, Date.current)
      assert_equal BigDecimal("110"), limit.limit_usd
      assert_equal Date.new(2026, 11, 20), limit.starts_on
      assert_equal "active", @workspace.billing.reload.plan_state
      assert_equal "Team, 20–30 Nov 2026", charge.invoice.line_name
    end
  end

  test "an admin can't activate a plan without billing details and a card" do
    travel_to Time.zone.local(2026, 11, 20, 10) do
      assert_nil plans(Date.current).choose!(@team)
      assert_equal "pending", @workspace.billing.reload.plan_state
      assert_equal @team, @workspace.reload.ai_plan
      assert_raises(Billing::NotReady) { plans(Date.current).activate! }
      assert_empty @billing_gateway.charges
      assert_match "starts once billing details and a card are added", plans(Date.current).preview(@team).summary
    end
  end

  test "an upgrade on day 16 of 30 from $300 to $600 charges $150 and raises the limit to $450" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans(Date.current).choose!(@team) }
    travel_to Time.zone.local(2026, 11, 16, 12) do
      preview = plans(Date.current).preview(@growth)
      assert_equal "Growth starts now: $150.00 + VAT is charged today for 16–30 Nov, and this month’s limit becomes $450.00.", preview.summary
      charge = plans(Date.current).choose!(@growth)
      assert charge.succeeded?
      assert_equal BigDecimal("150"), charge.net_usd
      assert_equal BigDecimal("450"), AiMonthLimit.for(@workspace, Date.current).limit_usd
      assert_equal @growth, @workspace.reload.ai_plan
    end
  end

  test "a downgrade applies from next month and charges nothing now" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans(Date.current).choose!(@team) }
    travel_to Time.zone.local(2026, 11, 10, 12) do
      assert_nil plans(Date.current).choose!(@starter)
      assert_equal @team, @workspace.reload.ai_plan
      assert_equal @starter, @workspace.billing.reload.pending_ai_plan
      assert_equal 1, @billing_gateway.charges.size
    end
  end

  test "a failed charge creates no invoice and leaves the plan not active" do
    billing_ready!(@workspace)
    @billing_gateway.fail_next!("insufficient funds")
    travel_to Time.zone.local(2026, 11, 20, 10) do
      charge = plans(Date.current).choose!(@team)
      assert charge.failed?
      assert_equal "insufficient funds", charge.failure_message
      assert_nil charge.invoice
      assert_equal 0, Invoice.count
      assert_equal "pending", @workspace.billing.reload.plan_state
    end
  end

  test "cancel keeps the paid month; keep plan undoes it" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans(Date.current).choose!(@team) }
    travel_to Time.zone.local(2026, 11, 12) do
      plans(Date.current).cancel!
      account = @workspace.billing.reload
      assert_equal "cancelling", account.plan_state
      assert_equal Date.new(2026, 11, 30), account.plan_ends_on
      assert account.plan_running?
      plans(Date.current).keep!
      assert_equal "active", account.reload.plan_state
    end
  end

  test "staff repricing a plan leaves a paid month's limit alone" do
    billing_ready!(@workspace)
    travel_to Time.zone.local(2026, 11, 20, 10) do
      plans(Date.current).choose!(@team)
      @team.update!(monthly_price_usd: 400)
      assert_equal BigDecimal("110"), AiMonthLimit.for(@workspace, Date.current).limit_usd
    end
  end

  test "an EU business pays no VAT, a reverse charge" do
    billing_ready!(@workspace, country: "DE", vat_number: "DE123456789")
    travel_to Time.zone.local(2026, 12, 1, 6) do
      charge = plans(Date.current).choose!(@team)
      assert_equal BigDecimal("0"), charge.vat_usd
      assert_equal "eu_reverse_charge", charge.vat_treatment
      assert_equal 30000, @billing_gateway.charges.last[:cents]
    end
  end
end
