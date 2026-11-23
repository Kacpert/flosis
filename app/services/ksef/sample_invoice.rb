require "bigdecimal"
require "securerandom"

module Ksef
  # A made-up invoice for smoke-testing KSeF's TEST/DEMO environments
  # (rake ksef:smoke): fictional companies with checksum-valid NIPs, one
  # 100 USD line, a unique number so KSeF never sees it as a duplicate.
  module SampleInvoice
    RATE = BigDecimal("4.0123") # a plausible NBP USD rate; not a real table

    module_function

    def build(seller_nip:, vat_treatment: :pl_23, issued_on: Date.current)
      net = BigDecimal("100.00")
      vat = vat_treatment == :pl_23 ? (net * BigDecimal("0.23")).round(2) : BigDecimal("0")
      Invoice.new(
        number: "SMOKE/#{Time.now.utc.strftime('%Y%m%d%H%M%S')}/#{SecureRandom.hex(3).upcase}",
        issued_on: issued_on,
        sold_on: issued_on,
        currency: "USD",
        seller: Party.new(name: "Flosis Test sp. z o.o.", nip: seller_nip, country_code: "PL",
                          address_line1: "ul. Testowa 1", address_line2: "00-001 Warszawa"),
        buyer: buyer(vat_treatment),
        vat_treatment: vat_treatment,
        lines: [ Line.new(name: "Flosis subscription (test)", net: net, vat_rate: (23 if vat_treatment == :pl_23), vat: vat, gross: net + vat) ],
        net: net, vat: vat, gross: net + vat,
        exchange_rate: (RATE if vat.positive?),
        exchange_rate_date: (issued_on - 1 if vat.positive?),
        vat_pln: ((vat * RATE).round(2) if vat.positive?),
        paid_on: issued_on
      )
    end

    def buyer(vat_treatment)
      case vat_treatment
      when :pl_23
        Party.new(name: "Klient Testowy sp. z o.o.", nip: Nip.random, country_code: "PL",
                  address_line1: "ul. Przykładowa 2", address_line2: "30-001 Kraków")
      when :eu_reverse_charge
        Party.new(name: "Testkunde GmbH", eu_vat_number: "DE#{format('%09d', SecureRandom.random_number(1_000_000_000))}",
                  country_code: "DE", address_line1: "Teststraße 1, 10115 Berlin")
      else
        Party.new(name: "Test Customer Inc.", tax_id: nil, country_code: "US", address_line1: "1 Test Street, Springfield, IL")
      end
    end
  end
end
