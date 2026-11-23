# What VAT an invoice carries, decided by the buyer's country (only companies
# buy): a Polish company pays 23%; an EU business with a valid EU VAT number gets
# a reverse charge; outside the EU the service is not subject to Polish VAT.
module Billing
  module Vat
    EU = %w[AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE].freeze

    Treatment = Data.define(:kind, :rate) do
      def vat_on(net)
        (BigDecimal(net.to_s) * rate / 100).round(2)
      end

      def gross(net)
        BigDecimal(net.to_s) + vat_on(net)
      end

      def charged?
        rate.positive?
      end

      def number_required?
        kind != :non_eu
      end

      def number_label
        { pl_23: "NIP", eu_reverse_charge: "EU VAT NUMBER", non_eu: "TAX ID (OPTIONAL)" }.fetch(kind)
      end

      def note
        {
          pl_23: "Polish company: invoices carry 23% VAT.",
          eu_reverse_charge: "EU business with a valid EU VAT number: reverse charge, no Polish VAT.",
          non_eu: "Outside the EU: invoices are not subject to Polish VAT."
        }.fetch(kind)
      end

      # The Billing details card's foot.
      def details_note
        {
          pl_23: "A Polish company: invoices carry 23% VAT, also shown in PLN at the NBP rate.",
          eu_reverse_charge: "An EU business: reverse charge, invoices carry no Polish VAT.",
          non_eu: "Outside the EU: invoices are not subject to Polish VAT."
        }.fetch(kind)
      end

      def short_label
        { pl_23: "23% VAT", eu_reverse_charge: "reverse charge", non_eu: "no Polish VAT" }.fetch(kind)
      end
    end

    module_function

    def for(country_code)
      code = country_code.to_s.upcase
      if code == "PL" then Treatment.new(kind: :pl_23, rate: BigDecimal("23"))
      elsif EU.include?(code) then Treatment.new(kind: :eu_reverse_charge, rate: BigDecimal("0"))
      else Treatment.new(kind: :non_eu, rate: BigDecimal("0"))
      end
    end

    def eu?(country_code)
      EU.include?(country_code.to_s.upcase)
    end
  end
end
