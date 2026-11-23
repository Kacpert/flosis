require "test_helper"

class Billing::TopUpsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    @team = billing_plan(price: 300)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace).choose!(@team) }
  end

  def run!(price, funding: "plan", at: Time.current)
    AiRun.create!(workspace: @workspace, area: "task_conversations", automation: "test", status: "succeeded",
                  cost_usd: price / BigDecimal("1.3"), price_usd: price, margin_percent: 30, ran_at: at, funding: funding)
  end

  test "a $200 top-up is charged now with VAT and shows as a $200 balance" do
    travel_to Time.zone.local(2026, 11, 20, 11) do
      charge = Billing::TopUps.new(@workspace.reload, user: users(:one)).buy!(200)
      assert charge.succeeded?
      assert_equal 24600, @billing_gateway.charges.last[:cents]
      assert_equal "Top-up", charge.invoice.line_name
      assert_equal BigDecimal("200"), Billing::Ledger.balance(@workspace)
      run!(BigDecimal("13"), funding: "top_up")
      assert_equal BigDecimal("187"), Billing::Ledger.balance(@workspace)
    end
  end

  test "only $100, $200 or $300, and only with an active plan" do
    assert_raises(Billing::NotReady) { Billing::TopUps.new(@workspace.reload).buy!(150) }
    @workspace.billing.update!(plan_state: "pending")
    assert_raises(Billing::NotReady) { Billing::TopUps.new(@workspace.reload).buy!(100) }
  end

  test "the automatic top-up fires when the limit is reached and the balance runs out, at most 3 times a month" do
    @workspace.billing.update!(auto_top_up: true, auto_top_up_usd: 100)
    travel_to Time.zone.local(2026, 11, 21, 12) do
      assert_nil Billing::TopUps.new(@workspace.reload).auto!, "under the limit"
      run!(BigDecimal("300"))
      3.times do |index|
        charge = Billing::TopUps.new(@workspace.reload).auto!
        assert charge&.succeeded?, "top-up #{index + 1}"
        assert_nil Billing::TopUps.new(@workspace.reload).auto!, "balance left"
        run!(BigDecimal("100"), funding: "top_up")
        travel 10.minutes
      end
      assert_nil Billing::TopUps.new(@workspace.reload).auto!
      assert Billing::TopUps.new(@workspace.reload).paused_until_next_month?
      assert_equal 3, @billing_gateway.charges.count { |c| c[:off_session] && c[:cents] == 12300 }
    end
  end

  test "a failed automatic top-up is not tried again by the next run" do
    @workspace.billing.update!(auto_top_up: true)
    travel_to Time.zone.local(2026, 11, 21, 12) do
      run!(BigDecimal("300"))
      @billing_gateway.fail_next!
      assert Billing::TopUps.new(@workspace.reload).auto!.failed?
      travel 1.hour
      assert_nil Billing::TopUps.new(@workspace.reload).auto!
    end
  end
end
