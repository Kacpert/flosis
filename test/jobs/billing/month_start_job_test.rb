require "test_helper"

class Billing::MonthStartJobTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    @team = billing_plan(name: "Team", price: 300)
    @starter = billing_plan(name: "Starter", price: 200)
    travel_to(Time.zone.local(2026, 11, 20, 10)) { Billing::Plans.new(@workspace.reload).choose!(@team) }
  end

  test "on the 1st the plan price is charged upfront and the month's limit is the full price" do
    travel_to Time.zone.local(2026, 12, 1, 6) do
      Billing::MonthStartJob.perform_now
      charge = @workspace.billing_charges.plan_charges.for_month(Date.current).sole
      assert charge.succeeded?
      assert_equal BigDecimal("300"), charge.net_usd
      assert_equal 36900, @billing_gateway.charges.last[:cents]
      assert @billing_gateway.charges.last[:off_session]
      assert_equal "Team, December 2026", charge.invoice.line_name
      limit = AiMonthLimit.for(@workspace, Date.current)
      assert_equal BigDecimal("300"), limit.limit_usd
      assert_not limit.partial?
      Billing::MonthStartJob.perform_now
      assert_equal 1, @workspace.billing_charges.plan_charges.for_month(Date.current).count, "charged once"
    end
  end

  test "a plan cancelled last month ends on the 1st and nothing is charged" do
    travel_to(Time.zone.local(2026, 11, 25)) { Billing::Plans.new(@workspace.reload).cancel! }
    travel_to Time.zone.local(2026, 12, 1, 6) do
      Billing::MonthStartJob.perform_now
      assert_equal "ended", @workspace.billing.reload.plan_state
      assert_nil @workspace.reload.ai_plan
      assert_equal 0, @workspace.billing_charges.for_month(Date.current).count
    end
  end

  test "a downgrade starts on the 1st and is charged at its price" do
    travel_to(Time.zone.local(2026, 11, 25)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    travel_to Time.zone.local(2026, 12, 1, 6) do
      Billing::MonthStartJob.perform_now
      assert_equal @starter, @workspace.reload.ai_plan
      assert_equal BigDecimal("200"), @workspace.billing_charges.plan_charges.for_month(Date.current).sole.net_usd
    end
  end

  test "a failed charge is retried on days 3, 5 and 7, then it is unpaid" do
    @billing_gateway.fail_next!("insufficient funds", times: 4)
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    charge = @workspace.billing_charges.plan_charges.for_month(Date.new(2026, 12, 1)).sole
    assert charge.failed?
    assert_nil charge.invoice
    assert_equal Date.new(2026, 12, 3), charge.next_retry_on
    { 2 => 1, 3 => 2, 4 => 2, 5 => 3, 7 => 4, 8 => 4 }.each do |day, attempts|
      travel_to(Time.zone.local(2026, 12, day, 6, 30)) { Billing::RetryJob.perform_now }
      assert_equal attempts, charge.reload.attempts, "attempts after day #{day}"
    end
    assert_nil charge.next_retry_on
    assert charge.unpaid?(Date.new(2026, 12, 8))
    assert_not charge.unpaid?(Date.new(2026, 12, 7))
    assert_equal 0, Invoice.where(billing_charge: charge).count
  end

  test "a retry that succeeds invoices and sets the full limit" do
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to(Time.zone.local(2026, 12, 3, 6, 30)) { Billing::RetryJob.perform_now }
    charge = @workspace.billing_charges.plan_charges.for_month(Date.new(2026, 12, 1)).sole
    assert charge.succeeded?
    assert charge.invoice
    assert_equal BigDecimal("300"), AiMonthLimit.for(@workspace, Date.new(2026, 12, 1)).limit_usd
  end

  test "a new card is charged straight away for the failed month" do
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to Time.zone.local(2026, 12, 2, 9) do
      retried = Billing::Card.new(@workspace.reload).save!("cs_new", return_url: "https://app/return")
      assert retried.succeeded?
      assert_equal "pm_cs_new", @workspace.billing.reload.stripe_payment_method_id
    end
  end

  test "last month's unpaid charge is abandoned on the 1st and the new month charged" do
    @billing_gateway.fail_next!("insufficient funds")
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to(Time.zone.local(2027, 1, 1, 6)) { Billing::MonthStartJob.perform_now }
    assert_equal "abandoned", @workspace.billing_charges.plan_charges.for_month(Date.new(2026, 12, 1)).sole.status
    assert @workspace.billing_charges.plan_charges.for_month(Date.new(2027, 1, 1)).sole.succeeded?
  end
end
