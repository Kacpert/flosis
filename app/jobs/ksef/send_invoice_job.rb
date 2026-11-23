# Sends one invoice to KSeF (SCRUM-71) and, once KSeF gives it a number,
# emails its PDF to every organization administrator. The VAT's PLN rate is
# taken first; the XML is built once and kept, so the QR code hashes exactly
# what KSeF took. Still deciding: asked again shortly. Refused by KSeF, or
# still failing after a few tries: Flosis staff are emailed and retry it from
# /hidmin. The charge and the invoice stand whatever KSeF says.
module Ksef
  class SendInvoiceJob < ApplicationJob
    queue_as :default
    # One send per invoice at a time: two copies would both reach KSeF and
    # email the admins twice.
    limits_concurrency to: 1, key: ->(invoice, **) { "ksef-invoice-#{invoice.id}" }, duration: 15.minutes

    QUIET_TRIES = 3
    PENDING_CHECKS = 10

    # Where the KSeF client comes from; tests put a fake here.
    class_attribute :client_factory, default: -> { Ksef::Client.from_env }

    def perform(invoice, check: 0)
      return if invoice.sent_to_ksef?

      client = client_factory.call
      return failed!(invoice, "KSeF is not set up (KSEF_NIP and a token or certificate)", tell_staff: true) unless client

      invoice.take_exchange_rate!
      unless invoice.ksef_xml
        invoice.update!(ksef_xml: Ksef::Fa3.new(invoice.to_ksef).to_xml)
      end

      session_ref, invoice_ref = invoice.ksef_reference&.split("/", 2)
      result = session_ref ? client.invoice_status(session_ref, invoice_ref) : client.send_invoice(invoice.ksef_xml)
      invoice.increment!(:ksef_attempts) unless session_ref
      record(invoice, result, check)
    rescue NbpRate::Unavailable => e
      # NBP not answering: tried again quietly a few times before staff hear.
      invoice.increment!(:ksef_attempts)
      quiet = invoice.ksef_attempts < QUIET_TRIES
      failed!(invoice, e.message, tell_staff: !quiet)
      self.class.set(wait: (10 * invoice.ksef_attempts).minutes).perform_later(invoice) if quiet
    rescue Ksef::ConfigurationError, ArgumentError => e
      # The invoice can't be built (seller details, a bad NIP): staff fix it.
      failed!(invoice, e.message, tell_staff: true)
    end

    private

    def record(invoice, result, check)
      case result.status
      when :accepted
        invoice.update!(ksef_status: "sent", ksef_number: result.ksef_number, ksef_sent_at: Time.current, ksef_error: nil)
        BillingMailer.invoice(invoice).deliver_later if invoice.emailed_at.nil?
      when :pending
        invoice.update!(ksef_reference: result.reference_number || invoice.ksef_reference, ksef_status: "pending")
        if check < PENDING_CHECKS
          self.class.set(wait: 2.minutes).perform_later(invoice, check: check + 1)
        else
          failed!(invoice, "KSeF has not decided yet (#{result.error || 'still processing'})", tell_staff: true)
        end
      when :rejected
        invoice.update!(ksef_reference: nil)
        failed!(invoice, result.error, tell_staff: true)
      else
        quiet = invoice.ksef_attempts < QUIET_TRIES
        failed!(invoice, result.error, tell_staff: !quiet)
        self.class.set(wait: (10 * invoice.ksef_attempts).minutes).perform_later(invoice) if quiet
      end
    end

    def failed!(invoice, reason, tell_staff:)
      invoice.update!(ksef_status: "failed", ksef_error: reason.to_s.truncate(250))
      StaffMailer.ksef_failed(invoice).deliver_later if tell_staff
    end
  end
end
