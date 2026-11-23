# KSeF (Krajowy System e-Faktur) is Poland's national e-invoicing system:
# every VAT invoice Flosis issues has to be sent there as FA(3) XML. This
# module holds the plain data the app hands in (an Invoice with its Parties and
# Lines), the result of a send, and the environment-wide helpers (which KSeF
# environment we talk to, and the KOD I verification link printed on the
# invoice). The moving parts live under Ksef:: — Fa3 (the XML), Client (the
# API), Auth/Xades/Crypto (getting in), Qr (the link).
module Ksef
  class Error < StandardError; end

  # Settings are missing or unreadable (a cert path that isn't there, …).
  class ConfigurationError < Error; end

  # KSeF could not be reached (timeout, DNS, TLS, connection reset).
  class TransportError < Error; end

  # KSeF answered with an error. `code` is KSeF's own error code (e.g. 21405)
  # when it sent one; the message is short and never carries a token or key.
  class ApiError < Error
    attr_reader :http_status, :code, :description, :details

    def initialize(http_status:, code: nil, description: nil, details: [])
      @http_status = http_status
      @code = code
      @description = description
      @details = Array(details)
      text = [ description.presence || "HTTP #{http_status}", @details.first(2).join("; ").presence ].compact.join(": ")
      super("KSeF #{http_status}: #{text.truncate(300)}#{" (code #{code})" if code}")
    end
  end

  # Logging in to KSeF finished with a refusal (bad signature, no permission, …).
  class AuthError < Error; end

  # Seller is a Polish company (nip, country_code "PL"). A buyer is one of:
  #   Polish company — nip, country_code "PL"
  #   EU business    — eu_vat_number with its country prefix ("DE123456789")
  #   outside the EU — tax_id (may be nil), country_code ("US")
  Party = Data.define(:name, :nip, :eu_vat_number, :tax_id, :country_code, :address_line1, :address_line2) do
    def initialize(name:, nip: nil, eu_vat_number: nil, tax_id: nil, country_code: nil, address_line1: nil, address_line2: nil)
      super
    end
  end

  # One invoice line in the invoice currency: net/vat/gross are BigDecimal,
  # vat_rate is 23 for Polish VAT and nil when no Polish VAT applies.
  Line = Data.define(:name, :net, :vat_rate, :vat, :gross)

  # vat_treatment: :pl_23 | :eu_reverse_charge | :non_eu
  # exchange_rate/exchange_rate_date: NBP mid rate (PLN per 1 unit of currency)
  # and the date of its table — only when there is VAT to convert, else nil.
  Invoice = Data.define(
    :number, :issued_on, :sold_on, :currency,
    :seller, :buyer,
    :vat_treatment,
    :lines, :net, :vat, :gross,
    :exchange_rate, :exchange_rate_date,
    :vat_pln,
    :paid_on
  )

  # status:
  #   :accepted — KSeF took the invoice; ksef_number is set. (A resend that
  #               KSeF calls a duplicate (440) is :accepted with the ORIGINAL
  #               number and a note in error.)
  #   :rejected — KSeF refused it (error: KSeF's description + code); it is not in KSeF — fix the data and send again
  #   :pending  — KSeF has it but hasn't decided, or couldn't be asked; poll Client#invoice_status
  #   :failed   — transport/auth problem, or KSeF dropped it for internal reasons (405/500/550);
  #               sending the same XML again is safe
  # reference_number: "SESSION_REF/INVOICE_REF" (KSeF reference numbers never
  # contain "/"), set once the invoice was handed to KSeF; session_reference
  # and invoice_reference split it for Client#invoice_status.
  SendResult = Data.define(:status, :ksef_number, :reference_number, :error) do
    def initialize(status:, ksef_number: nil, reference_number: nil, error: nil)
      super
    end

    def accepted? = status == :accepted
    def rejected? = status == :rejected
    def pending? = status == :pending
    def failed? = status == :failed

    def session_reference = reference_number&.split("/", 2)&.first
    def invoice_reference = reference_number&.split("/", 2)&.last
  end

  ENVIRONMENTS = {
    test: { api: "https://api-test.ksef.mf.gov.pl/v2", qr: "https://qr-test.ksef.mf.gov.pl" },
    demo: { api: "https://api-demo.ksef.mf.gov.pl/v2", qr: "https://qr-demo.ksef.mf.gov.pl" },
    production: { api: "https://api.ksef.mf.gov.pl/v2", qr: "https://qr.ksef.mf.gov.pl" }
  }.freeze

  ENV_NAMES = {
    "" => :test, "test" => :test, "te" => :test,
    "demo" => :demo,
    "production" => :production, "prod" => :production
  }.freeze

  # From ENV KSEF_ENV (test | demo | production), :test when unset. A value
  # that is set but unknown raises rather than quietly sending to TEST.
  def self.environment
    raw = ENV["KSEF_ENV"].to_s.strip.downcase
    ENV_NAMES.fetch(raw) { raise ConfigurationError, "Unknown KSEF_ENV #{raw.inspect} (use test, demo or production)" }
  end

  def self.api_url(environment = self.environment)
    ENVIRONMENTS.fetch(environment).fetch(:api)
  end

  # The KOD I link for the invoice's QR code (see Ksef::Qr). `xml` must be the
  # exact bytes sent to KSeF.
  def self.qr_url(seller_nip:, issued_on:, xml:, environment: self.environment)
    Qr.invoice_url(seller_nip: seller_nip, issued_on: issued_on, xml: xml, environment: environment)
  end
end
