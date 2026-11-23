require "test_helper"
require "webmock/minitest"

# SCRUM-71: an invoice reaches KSeF, and only then the admins' inbox; a
# failed send tells staff, and the invoice stands.
class Ksef::SendInvoiceJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  class FakeClient
    attr_reader :sent

    def initialize(*results)
      @results = results
      @sent = []
    end

    def send_invoice(xml)
      @sent << xml
      @results.shift
    end

    def invoice_status(_session, _invoice) = @results.shift
  end

  setup do
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    users(:two).update!(flosis_staff: true)
    stub_request(:get, %r{api.nbp.pl}).to_return(body: { rates: [ { no: "210/A/NBP/2026", effectiveDate: "2026-10-30", mid: 3.6512 } ] }.to_json)
    @env = { "INVOICE_SELLER_NAME" => "Flosis Sp. z o.o.", "INVOICE_SELLER_NIP" => "5261040828", "INVOICE_SELLER_STREET" => "ul. Testowa 1",
             "INVOICE_SELLER_POSTAL_CODE" => "00-001", "INVOICE_SELLER_CITY" => "Warszawa", "KSEF_ENV" => "test" }
    travel_to Time.zone.local(2026, 11, 1, 6)
    @charge = Billing::Plans.new(@workspace.reload).choose!(billing_plan(name: "Starter", price: 200))
    @invoice = @charge.invoice
  end

  teardown { Ksef::SendInvoiceJob.client_factory = -> { Ksef::Client.from_env } }

  def with_client(client)
    Ksef::SendInvoiceJob.client_factory = -> { client }
    with_env(@env) { yield }
  end

  test "the charge queued its invoice for KSeF" do
    assert_enqueued_with(job: Ksef::SendInvoiceJob, args: [ @invoice ])
  end

  test "accepted: the KSeF number is kept, the VAT in PLN is taken, then the admins get the PDF" do
    client = FakeClient.new(Ksef::SendResult.new(status: :accepted, ksef_number: "5261040828-20261101-ABC-71", reference_number: "S/I"))
    with_client(client) do
      assert_enqueued_email_with(BillingMailer, :invoice, args: [ @invoice ]) { Ksef::SendInvoiceJob.perform_now(@invoice) }
    end
    @invoice.reload
    assert_equal "sent", @invoice.ksef_status
    assert_equal "5261040828-20261101-ABC-71", @invoice.ksef_number
    assert_equal BigDecimal("167.96"), @invoice.vat_pln
    assert_equal Date.new(2026, 10, 30), @invoice.exchange_rate_date
    assert_equal client.sent.first, @invoice.ksef_xml
    assert_includes @invoice.ksef_xml, "FS/001/11/2026"
    assert_match %r{\Ahttps://qr-test.ksef.mf.gov.pl/invoice/5261040828/01-11-2026/}, with_env(@env) { @invoice.qr_url }
    assert with_env(@env) { InvoicePdf.new(@invoice).render }.start_with?("%PDF")
  end

  test "rejected: staff are emailed with the reason, the admins get nothing yet, and Retry sends again" do
    client = FakeClient.new(Ksef::SendResult.new(status: :rejected, error: "Rejected by KSeF: buyer NIP not found (code 21405)"),
                            Ksef::SendResult.new(status: :accepted, ksef_number: "N-1", reference_number: "S/I"))
    with_client(client) do
      assert_enqueued_email_with(StaffMailer, :ksef_failed, args: [ @invoice ]) { Ksef::SendInvoiceJob.perform_now(@invoice) }
      assert_equal "failed", @invoice.reload.ksef_status
      assert_equal "Rejected by KSeF: buyer NIP not found (code 21405)", @invoice.ksef_error
      mail = StaffMailer.ksef_failed(@invoice)
      assert_equal "KSeF send failed: FS/001/11/2026 · #{@workspace.name}", mail.subject
      assert_includes mail.text_part.body.to_s, "Reason: Rejected by KSeF: buyer NIP not found (code 21405)"
      Ksef::SendInvoiceJob.perform_now(@invoice.reload)
      assert_equal "sent", @invoice.reload.ksef_status
    end
  end

  test "a transport failure is retried quietly before staff hear of it" do
    client = FakeClient.new(*Array.new(3) { Ksef::SendResult.new(status: :failed, error: "KSeF could not be reached") })
    with_client(client) do
      assert_no_enqueued_emails { Ksef::SendInvoiceJob.perform_now(@invoice) }
      assert_enqueued_with(job: Ksef::SendInvoiceJob)
      Ksef::SendInvoiceJob.perform_now(@invoice.reload)
      assert_enqueued_email_with(StaffMailer, :ksef_failed, args: [ @invoice ]) { Ksef::SendInvoiceJob.perform_now(@invoice.reload) }
    end
  end

  test "KSeF not set up: staff are told" do
    with_env("KSEF_NIP" => nil, "KSEF_TOKEN" => nil, "KSEF_CERT_PATH" => nil) do
      Ksef::SendInvoiceJob.client_factory = -> { Ksef::Client.from_env }
      assert_enqueued_email_with(StaffMailer, :ksef_failed, args: [ @invoice ]) { Ksef::SendInvoiceJob.perform_now(@invoice) }
    end
    assert_equal "KSeF is not set up (KSEF_NIP and a token or certificate)", @invoice.reload.ksef_error
  end

  test "NBP not answering is retried quietly, then staff hear" do
    stub_request(:get, %r{api.nbp.pl}).to_return(status: 503)
    client = FakeClient.new
    with_client(client) do
      assert_no_enqueued_emails { Ksef::SendInvoiceJob.perform_now(@invoice) }
      assert_enqueued_with(job: Ksef::SendInvoiceJob)
      Ksef::SendInvoiceJob.perform_now(@invoice.reload)
      assert_enqueued_email_with(StaffMailer, :ksef_failed, args: [ @invoice ]) { Ksef::SendInvoiceJob.perform_now(@invoice.reload) }
    end
    assert_empty client.sent
  end

  test "an invoice that can't be built tells staff at once" do
    with_client(FakeClient.new) do
      with_env("INVOICE_SELLER_NIP" => "123") do
        assert_enqueued_email_with(StaffMailer, :ksef_failed, args: [ @invoice ]) { Ksef::SendInvoiceJob.perform_now(@invoice) }
      end
    end
    assert_equal "failed", @invoice.reload.ksef_status
  end
end
