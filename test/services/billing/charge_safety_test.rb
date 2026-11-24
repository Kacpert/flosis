require "test_helper"
require "webmock/minitest"

# SCRUM-71: money is never taken twice, never lost, and a failing month stays
# failing until it is paid — the cases a whole-branch review found.
class Billing::ChargeSafetyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    @starter = billing_plan(name: "Starter", price: 200)
    @growth = billing_plan(name: "Growth", price: 600)
  end

  def plans = Billing::Plans.new(@workspace.reload, user: users(:one))
  def limit = AiMonthLimit.for(@workspace, Date.current).limit_usd

  test "a 3-D Secure return page reloaded applies the upgrade once" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 22, 10) do
      @billing_gateway.require_action_next!
      charge = plans.choose!(@growth)
      assert_equal "requires_action", charge.status
      3.times { Billing::Charger.new(@workspace.reload).settle!(charge.reload, @billing_gateway.payment_result(charge.stripe_payment_intent_id)) }
      assert_equal BigDecimal("320"), limit
      assert_equal 1, Invoice.where(billing_charge: charge).count
      assert_no_enqueued_jobs only: Ksef::SendInvoiceJob do
        Billing::Charger.new(@workspace.reload).settle!(charge.reload, @billing_gateway.payment_result(charge.stripe_payment_intent_id))
      end
    end
  end

  test "a failing month stays failing while the new card waits for 3-D Secure" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to Time.zone.local(2026, 12, 2, 9) do
      @billing_gateway.require_action_next!
      retried = Billing::Card.new(@workspace.reload).save!("cs_new", return_url: "https://app/return")
      assert_equal "failed", retried.status
      assert Billing::Allowance.for(@workspace).payment_failing?
      assert_raises(Billing::NotReady) { plans.choose!(@growth) }
      @billing_gateway.settle!(retried.stripe_payment_intent_id, status: :requires_action)
      @unfinished = retried.stripe_payment_intent_id
    end
    travel_to(Time.zone.local(2026, 12, 4, 6, 30)) { Billing::RetryJob.perform_now }
    assert_includes @billing_gateway.cancelled, @unfinished, "the unfinished 3-D Secure payment is cancelled before trying again"
  end

  test "a 3-D Secure payment left a day is looked up: paid after all, it is settled; otherwise cancelled" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 10, 9) do
      @billing_gateway.require_action_next!
      paid = Billing::TopUps.new(@workspace.reload).buy!(100)
      @billing_gateway.require_action_next!
      left = Billing::TopUps.new(@workspace.reload).buy!(200)
      @billing_gateway.settle!(left.stripe_payment_intent_id, status: :requires_action)
      travel 25.hours
      Billing::RetryJob.perform_now
      assert paid.reload.succeeded?
      assert_equal BigDecimal("100"), Billing::Ledger.balance(@workspace)
      assert_equal "abandoned", left.reload.status
      assert_includes @billing_gateway.cancelled, left.stripe_payment_intent_id
    end
  end

  test "an upgrade at 02:00 on the 1st charges the month first, then only the difference" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to Time.zone.local(2026, 12, 1, 2) do
      plans.choose!(@growth)
      nets = @workspace.billing_charges.for_month(Date.current).order(:id).pluck(:kind, :net_usd)
      assert_equal [ [ "plan", BigDecimal("200") ], [ "upgrade", BigDecimal("400") ] ], nets
      assert_equal BigDecimal("600"), limit
      Billing::MonthStartJob.perform_now
      assert_equal 2, @workspace.billing_charges.for_month(Date.current).count, "the 06:00 run charges nothing more"
    end
  end

  test "an upgrade's difference is from the price paid this month, even after staff reprice the plan" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    @starter.update!(monthly_price_usd: 500)
    travel_to Time.zone.local(2026, 11, 16, 12) do
      assert_equal BigDecimal("200"), plans.preview(@growth).net
    end
  end

  test "Activate pressed twice charges once" do
    @workspace.update!(ai_plan: @starter)
    @workspace.billing.update!(plan_state: "pending")
    travel_to Time.zone.local(2026, 11, 20, 10) do
      @billing_gateway.require_action_next!
      plans.activate!
      assert_nil plans.activate!
      assert_equal 1, @billing_gateway.charges.size
    end
  end

  test "Stripe unreachable: the charge waits, then is looked up by its key and never sent again" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 10, 9) do
      @billing_gateway.unknown_next!(went_through: true)
      taken = Billing::TopUps.new(@workspace.reload).buy!(100)
      @billing_gateway.unknown_next!
      lost = Billing::TopUps.new(@workspace.reload).buy!(200)
      assert_equal [ "pending", "pending" ], [ taken.status, lost.status ]
      sent = @billing_gateway.charges.size
      assert_enqueued_with(job: Billing::ResolveChargeJob, args: [ lost ])
      travel 11.minutes
      perform_enqueued_jobs(only: Billing::ResolveChargeJob)
      assert_equal sent, @billing_gateway.charges.size, "nothing is charged again"
      assert taken.reload.succeeded?
      assert_equal "failed", lost.reload.status
      assert_equal "Stripe could not be reached, so nothing was charged", lost.failure_message
      assert_equal BigDecimal("100"), Billing::Ledger.balance(@workspace)
    end
  end

  test "a payment whose outcome was unknown is found by the key it was sent with, after a rename too" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 10, 9) do
      @workspace.update!(name: "Acme Inc.")
      @billing_gateway.unknown_next!(went_through: true)
      charge = Billing::TopUps.new(@workspace.reload).buy!(100)
      assert_equal "flosis-acme-inc-top-up-#{charge.created_at.strftime("%Y%m%d-%H%M%S")}-#{charge.id}-1", charge.reload.stripe_key
      assert_equal charge.stripe_key, @billing_gateway.charges.last[:idempotency_key]
      assert_equal charge.stripe_key, @billing_gateway.charges.last[:metadata][:flosis_key]
      @workspace.update!(name: "Acme Group")
      travel 11.minutes
      perform_enqueued_jobs(only: Billing::ResolveChargeJob)
      assert charge.reload.succeeded?
    end
  end

  test "after a failed automatic top-up, a new card is tried at once" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    @workspace.billing.update!(auto_top_up: true)
    travel_to Time.zone.local(2026, 11, 21, 12) do
      AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "succeeded", cost_usd: 1, price_usd: 200, ran_at: Time.current, funding: "plan")
      @billing_gateway.fail_next!
      assert Billing::TopUps.new(@workspace.reload).auto!.failed?
      assert_nil Billing::TopUps.new(@workspace.reload).auto!
      travel 1.hour
      Billing::Card.new(@workspace.reload).save!("cs_new")
      assert_equal BigDecimal("100"), Billing::Ledger.balance(@workspace)
    end
  end

  test "staff assigning a plan from the plan form to a paying organization waits for the next charge" do
    travel_to(Time.zone.local(2026, 11, 20, 10)) { plans.choose!(@starter) }
    assert_equal :next_month, Billing::Plans.assign_by_staff!(@workspace.reload, @growth)
    assert_equal @starter, @workspace.reload.ai_plan
    assert_equal @growth, @workspace.billing.reload.pending_ai_plan
  end

  # Kacper (2026-11-24): the plan's month never carries over; the top-up
  # never expires, and while a payment fails it is a buffer after the 15%,
  # returned to the balance once the month is paid.
  test "a failing month runs on the 15%, then on the top-up, which gets it back once the month is paid" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to(Time.zone.local(2026, 11, 10, 9)) { Billing::TopUps.new(@workspace.reload).buy!(100) }
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    run = ->(cost) { AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "succeeded", cost_usd: cost, price_usd: cost * BigDecimal("1.3"), ran_at: Time.current).tap { |r| Billing::Funding.assign!(r) } }
    travel_to Time.zone.local(2026, 12, 2, 10) do
      assert_equal "plan", run.(BigDecimal("23.08")).funding # $30.00 of grace
      assert Billing::Allowance.for(@workspace.reload).payment_failing?
      assert_not Billing::Allowance.for(@workspace).paused?, "the top-up keeps AI on"
      assert_equal "top_up", run.(BigDecimal("50")).funding
      assert_equal BigDecimal("35"), Billing::Ledger.balance(@workspace)
      assert_equal "top_up", run.(BigDecimal("50")).funding
      assert_equal :retry_spent, Billing::Allowance.for(@workspace).reason
    end
    travel_to Time.zone.local(2026, 12, 3, 9) do
      Billing::Card.new(@workspace.reload).save!("cs_new")
      assert_equal BigDecimal("100"), Billing::Ledger.balance(@workspace), "the top-up got back what it paid"
      assert_equal BigDecimal("160.004"), Billing::Ledger.plan_spend(@workspace).round(3)
      assert_not Billing::Allowance.for(@workspace).paused?
    end
  end

  test "the plan's month doesn't carry over: a new month starts from its own paid limit" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { plans.choose!(@starter) }
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to Time.zone.local(2026, 12, 2, 6) do
      assert_equal BigDecimal("200"), AiMonthLimit.for(@workspace, Date.current).limit_usd
      assert_equal BigDecimal("0"), Billing::Ledger.plan_spend(@workspace)
    end
  end
end
