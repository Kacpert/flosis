require "test_helper"

class BillingMailerTest < ActionMailer::TestCase
  setup do
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    @starter = billing_plan(name: "Starter", price: 200)
  end

  def seller_env(&)
    with_env("INVOICE_SELLER_NAME" => "Flosis Sp. z o.o.", "INVOICE_SELLER_NIP" => "5261040828", "INVOICE_SELLER_STREET" => "ul. Testowa 1",
             "INVOICE_SELLER_POSTAL_CODE" => "00-001", "INVOICE_SELLER_CITY" => "Warszawa", &)
  end

  def invoice_for(charge)
    invoice = charge.invoice
    invoice.update!(ksef_status: "sent", ksef_number: "5261040828-20261101-5B1E07A3C2-71", ksef_xml: "<Faktura/>",
                    exchange_rate: BigDecimal("3.6512"), exchange_rate_date: Date.new(2026, 10, 30), exchange_rate_table: "210/A/NBP/2026",
                    vat_pln: BigDecimal("167.96"))
    invoice
  end

  test "the plan invoice: to every admin, with the PDF, the VAT in PLN and the KSeF number" do
    seller_env do
      charge = travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
      mail = travel_to(Time.zone.local(2026, 11, 1, 6, 4)) { BillingMailer.invoice(invoice_for(charge)) }
      assert_equal [ users(:one).email_address ], mail.to
      assert_equal "Invoice FV/2026/11/0001 · Starter, November 2026", mail.subject
      assert_equal [ "FV-2026-11-0001.pdf" ], mail.attachments.map(&:filename)
      body = mail.html_part.body.to_s
      assert_includes body, "Your invoice for November"
      assert_includes body, "We charged Starter for November 2026 to your card."
      assert_includes body, "167.96 zł at the NBP rate of 3.6512 from 30 Oct 2026"
      assert_includes body, "KSeF 5261040828-20261101-5B1E07A3C2-71"
      assert_includes body, "Your next charge is on 1 Dec 2026."
      assert_includes mail.text_part.body.to_s, "Charged to Visa •••• 4242: $246.00"
      assert mail.attachments.first.body.to_s.start_with?("%PDF")
    end
  end

  test "the 3rd automatic top-up says automatic top-ups are paused until next month" do
    seller_env do
      travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
      travel_to Time.zone.local(2026, 11, 21, 22, 47) do
        charges = 3.times.map { Billing::Charger.new(@workspace.reload).charge!(kind: "auto_top_up", net: BigDecimal("100")) }
        mail = BillingMailer.invoice(invoice_for(charges.last))
        assert_equal "We topped up $100 · automatic top-ups paused until 1 Dec", mail.subject
        assert_includes mail.html_part.body.to_s, "We topped up $100, for the 3rd time this month"
        first = BillingMailer.invoice(invoice_for(charges.first))
        assert_equal "We topped up $100", first.subject
      end
    end
  end

  test "payment failed: the bank's reason, the 15% allowance and no invoice" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    @billing_gateway.fail_next!
    travel_to Time.zone.local(2026, 12, 1, 6, 2) do
      assert_enqueued_emails(1) { Billing::MonthStartJob.perform_now }
      charge = @workspace.billing_charges.plan_charges.for_month(Date.current).sole
      mail = BillingMailer.payment_failed(charge)
      assert_equal "Payment failed, update your card", mail.subject
      body = mail.text_part.body.to_s
      assert_includes body, "We couldn’t charge $246.00 to Visa •••• 4242 for Starter, December 2026."
      assert_includes body, "The bank said: insufficient funds."
      assert_includes body, "until 8 Dec"
      assert_includes body, "$30.00 of AI (15% of the plan)"
      assert_includes body, "No invoice is issued until the payment succeeds."
    end
  end

  test "80% once a month, and AI paused once per pause" do
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 18, 14) do
      AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "succeeded", cost_usd: 1, price_usd: 165, ran_at: Time.current, funding: "plan")
      assert_enqueued_email_with(BillingMailer, :usage_80, args: [ @workspace ]) { Billing::Notices.after_run(@workspace.reload) }
      assert_no_enqueued_emails { Billing::Notices.after_run(@workspace.reload) }
      mail = BillingMailer.usage_80(@workspace)
      assert_equal "You've used 80% of this month's AI limit", mail.subject
      assert_includes mail.text_part.body.to_s, "You’ve used 80% of this month’s AI limit ($160 of $200)."
      AiRun.create!(workspace: @workspace, area: "agents", automation: "T", status: "succeeded", cost_usd: 1, price_usd: 40, ran_at: Time.current, funding: "plan")
      assert_enqueued_email_with(BillingMailer, :limit_reached, args: [ @workspace ]) { Billing::Notices.after_run(@workspace.reload) }
      assert_no_enqueued_emails { Billing::Notices.after_run(@workspace.reload) }
      assert_equal "AI paused: this month's AI limit is reached", BillingMailer.limit_reached(@workspace).subject
    end
  end
end
