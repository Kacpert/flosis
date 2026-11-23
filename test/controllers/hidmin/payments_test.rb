require "test_helper"

# SCRUM-71: Flosis staff see each organization's payment status, top-up
# balance, automatic top-ups and every invoice with its KSeF status; a failed
# KSeF send is retried with one click.
class Hidmin::PaymentsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(billing_plan(name: "Scale", price: 1200)) }
  end

  test "Paid, with every invoice and its KSeF number" do
    @workspace.invoices.sole.update!(ksef_status: "sent", ksef_number: "7010123456-20261101-8F3A21C9B0-4D")
    travel_to Time.zone.local(2026, 11, 12, 10) do
      get hidmin_workspace_path(@workspace)
      assert_select "[data-payment-status]", text: /Paid/
      assert_select "[data-payment-status]", text: /November paid on 1 Nov · next charge 1 Dec 2026/
      assert_select "[data-ksef-invoice='FS/001/11/2026']", text: /Sent\s+7010123456-20261101-8F3A21C9B0-4D/
    end
  end

  test "Retrying · day 3 of 7, then Unpaid" do
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to Time.zone.local(2026, 12, 3, 10) do
      get hidmin_workspace_path(@workspace)
      assert_select "[data-payment-status]", text: /Retrying · day 3 of 7/
      assert_select "[data-payment-status]", text: /December’s \$1,476\.00 declined on 1 Dec · AI allowed up to \$180\.00 until it is paid/
    end
    travel_to Time.zone.local(2026, 12, 9, 10) do
      get hidmin_workspace_path(@workspace)
      assert_select "[data-payment-status]", text: /Unpaid/
    end
  end

  test "a failed KSeF send shows its reason and is retried with one click" do
    invoice = @workspace.invoices.sole
    invoice.update!(ksef_status: "failed", ksef_error: "Rejected by KSeF: buyer NIP not found (code 21405)")
    get hidmin_workspace_path(@workspace)
    assert_select "[data-ksef-invoice='FS/001/11/2026']", text: /Failed\s+Rejected by KSeF: buyer NIP not found \(code 21405\)/
    assert_enqueued_with(job: Ksef::SendInvoiceJob, args: [ invoice ]) do
      post retry_ksef_hidmin_invoice_path(invoice)
    end
    assert_equal "Sending FS/001/11/2026 to KSeF again.", flash[:clar_toast]
    assert_equal "pending", invoice.reload.ksef_status
  end

  test "an unknown-cost run counts toward the limit once staff set its cost; a legacy one never" do
    run = AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "failed", ran_at: Time.current)
    legacy = AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "failed", ran_at: Time.current, funding: "legacy")
    assert_equal BigDecimal("0"), Billing::Ledger.plan_spend(@workspace)
    patch set_cost_hidmin_ai_run_path(run), params: { cost_usd: "10" }
    patch set_cost_hidmin_ai_run_path(legacy), params: { cost_usd: "10" }
    assert_equal "plan", run.reload.funding
    assert_equal "legacy", legacy.reload.funding
    assert_equal run.price_usd, Billing::Ledger.plan_spend(@workspace)
  end

  test "a plan staff assign to a paying organization starts with the next charge" do
    growth = billing_plan(name: "Growth", price: 600)
    patch assign_plan_hidmin_workspace_path(@workspace), params: { ai_plan_id: growth.id }
    assert_equal growth, @workspace.billing.reload.pending_ai_plan
    assert_equal "Scale", @workspace.reload.ai_plan.name
  end
end
