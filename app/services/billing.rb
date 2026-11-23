# SCRUM-71: what organizations pay for AI. Flosis computes every amount (the
# plan upfront on the 1st, a partial first month, upgrades, top-ups) and
# charges a card that Stripe keeps; a charge that succeeds is invoiced and the
# invoice goes through KSeF. All money is in US dollars.
module Billing
  # Something the organization has to do first (billing details, a card).
  class NotReady < StandardError; end

  # Top-ups come in these amounts, bought by hand or automatically.
  TOP_UP_AMOUNTS = [ 100, 200, 300 ].map { |amount| BigDecimal(amount) }.freeze
  # Runs paid from the top-up balance are priced at cost + this margin.
  TOP_UP_MARGIN_PERCENT = BigDecimal("30")
  # Automatic top-ups a calendar month allows.
  AUTO_TOP_UPS_PER_MONTH = 3
  # While a plan charge is being retried, AI runs up to this share of the plan price.
  RETRY_GRACE_SHARE = BigDecimal("0.15")
  # Days a failed plan charge is retried (day 1 is the first attempt).
  RETRY_DAYS = 7
  RETRY_ON_DAYS = [ 3, 5, 7 ].freeze

  # The payment provider: Stripe in the app, a fake in tests.
  mattr_writer :gateway

  def self.gateway
    @@gateway ||= StripeGateway.new
  end

  # A charge went through and its invoice exists: send it to KSeF, which
  # emails it to the admins once it has a number.
  def self.invoice_issued(invoice)
    Ksef::SendInvoiceJob.perform_later(invoice) if invoice
  end

  # A charge failed: the admins are told (each attempt of a plan charge).
  def self.charge_failed(charge, first_attempt:)
    Notices.charge_failed(charge, first_attempt: first_attempt)
  end
end
