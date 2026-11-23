require "nokogiri"
require "bigdecimal"

module Ksef
  # Turns a Ksef::Invoice into FA(3) XML — the structured invoice schema
  # KSeF accepts (namespace http://crd.gov.pl/wzor/2025/06/25/13775/,
  # schema FA (3) 1-0E). Flosis sells services paid in full by card, so
  # every invoice is a basic VAT invoice ("VAT") with the "no" defaults in
  # Adnotacje, and one of three VAT treatments:
  #
  #   :pl_23             Polish 23% VAT. P_13_1/P_14_1 (net/VAT in the invoice
  #                      currency), P_14_1W (VAT in PLN, foreign currency only)
  #                      and KursWaluty on every line; lines P_12 "23".
  #   :eu_reverse_charge Service to an EU business, taxed where the buyer is
  #                      (art. 28b; art. 100 ust. 1 pkt 4): P_13_9, lines
  #                      P_12 "np II", P_18 = 1 ("odwrotne obciążenie"),
  #                      seller's PL prefix (PrefiksPodatnika), buyer KodUE+NrVatUE.
  #   :non_eu            Service outside the EU, not taxed in Poland:
  #                      P_13_8, lines P_12 "np I"; buyer KodKraju+NrID or BrakID.
  #
  # The XML is built once per invoice: KSeF and the QR code both hash the
  # exact bytes, so store what to_xml returned and send/hash that.
  class Fa3
    NAMESPACE = "http://crd.gov.pl/wzor/2025/06/25/13775/"
    SYSTEM_INFO = "Flosis"
    TREATMENTS = %i[pl_23 eu_reverse_charge non_eu].freeze
    LINE_RATE = { pl_23: "23", eu_reverse_charge: "np II", non_eu: "np I" }.freeze
    CARD = 2 # TFormaPlatnosci: 1 gotówka, 2 karta, 3 bon, 4 czek, 5 kredyt, 6 przelew, 7 mobilna
    UNIT = "szt."
    # FA(3) TKodyKrajowUE — VAT prefixes (Greece is EL, Northern Ireland XI).
    EU_VAT_PREFIXES = %w[AT BE BG CY CZ DK EE FI FR DE EL HR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE XI].freeze

    attr_reader :invoice

    def initialize(invoice, generated_at: Time.now)
      @invoice = invoice
      @generated_at = generated_at
      validate!
    end

    def to_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |x|
        x.Faktura(xmlns: NAMESPACE) do
          naglowek(x)
          podmiot1(x)
          podmiot2(x)
          fa(x)
        end
      end.to_xml
    end

    private

    def treatment = invoice.vat_treatment
    def foreign_currency? = invoice.currency.to_s.upcase != "PLN"

    def validate!
      raise ArgumentError, "Unknown vat_treatment #{treatment.inspect}" unless TREATMENTS.include?(treatment)
      raise ArgumentError, "Seller needs a valid NIP" unless Nip.valid?(invoice.seller.nip)
      raise ArgumentError, "Seller needs a name and an address" if invoice.seller.name.blank? || invoice.seller.address_line1.blank?
      raise ArgumentError, "Buyer NIP #{invoice.buyer.nip.inspect} is not a valid NIP" if invoice.buyer.nip.present? && !Nip.valid?(polish_nip(invoice.buyer.nip))
      raise ArgumentError, "Invoice needs at least one line" if invoice.lines.blank?
      raise ArgumentError, "An EU reverse-charge buyer needs an EU VAT number" if treatment == :eu_reverse_charge && invoice.buyer.eu_vat_number.blank?
      return unless treatment == :pl_23 && foreign_currency?

      raise ArgumentError, "A foreign-currency invoice with VAT needs exchange_rate and vat_pln" if invoice.exchange_rate.nil? || invoice.vat_pln.nil?
    end

    def naglowek(x)
      x.Naglowek do
        x.KodFormularza("FA", kodSystemowy: "FA (3)", wersjaSchemy: "1-0E")
        x.WariantFormularza(3)
        x.DataWytworzeniaFa(@generated_at.getutc.iso8601)
        x.SystemInfo(SYSTEM_INFO)
      end
    end

    def podmiot1(x)
      seller = invoice.seller
      x.Podmiot1 do
        # Art. 97 ust. 10 pkt 2: a service taxed in another EU country is
        # invoiced under the seller's PL-prefixed VAT-UE number.
        x.PrefiksPodatnika("PL") if treatment == :eu_reverse_charge
        x.DaneIdentyfikacyjne do
          x.NIP(seller.nip)
          x.Nazwa(text(seller.name))
        end
        adres(x, seller, "PL")
      end
    end

    def podmiot2(x)
      buyer = invoice.buyer
      x.Podmiot2 do
        x.DaneIdentyfikacyjne do
          buyer_identifier(x, buyer)
          x.Nazwa(text(buyer.name)) if buyer.name.present?
        end
        adres(x, buyer, buyer_country(buyer)) if buyer.address_line1.present?
        x.JST(2) # not a subordinate unit of a local government
        x.GV(2)  # not a member of a VAT group
      end
    end

    def buyer_identifier(x, buyer)
      if treatment == :eu_reverse_charge || (buyer.nip.blank? && buyer.eu_vat_number.present?)
        prefix, number = eu_vat(buyer)
        x.KodUE(prefix)
        x.NrVatUE(number)
      elsif buyer.nip.present?
        x.NIP(polish_nip(buyer.nip))
      elsif buyer.tax_id.present?
        x.KodKraju(buyer_country(buyer)) if buyer_country(buyer).present?
        x.NrID(text(buyer.tax_id, 50))
      else
        x.BrakID(1) # no tax id (e.g. a consumer outside the EU)
      end
    end

    def polish_nip(nip) = nip.to_s.delete("^0-9")

    # "DE 123 456 789" -> ["DE", "123456789"]; without a prefix, the
    # country code stands in (GR -> EL).
    def eu_vat(buyer)
      raw = buyer.eu_vat_number.to_s.upcase.gsub(/[^0-9A-Z+*]/, "")
      prefix = raw[0, 2]
      return [ prefix, raw[2..] ] if EU_VAT_PREFIXES.include?(prefix) && raw.length > 2

      country = buyer.country_code.to_s.upcase
      country = "EL" if country == "GR"
      raise ArgumentError, "Cannot tell the EU country of VAT number #{buyer.eu_vat_number.inspect}" unless EU_VAT_PREFIXES.include?(country)

      [ country, raw ]
    end

    def buyer_country(buyer)
      buyer.country_code.to_s.upcase.presence || (buyer.nip.present? ? "PL" : nil)
    end

    def adres(x, party, country)
      x.Adres do
        x.KodKraju(country)
        x.AdresL1(text(party.address_line1))
        x.AdresL2(text(party.address_line2)) if party.address_line2.present?
      end
    end

    def fa(x)
      x.Fa do
        x.KodWaluty(invoice.currency.to_s.upcase)
        x.P_1(date(invoice.issued_on))
        x.P_2(text(invoice.number))
        # P_6 is only filled when the sale date differs from the issue date.
        x.P_6(date(invoice.sold_on)) if invoice.sold_on && invoice.sold_on != invoice.issued_on
        totals(x)
        x.P_15(money(invoice.gross))
        adnotacje(x)
        x.RodzajFaktury("VAT")
        exchange_rate_note(x)
        invoice.lines.each_with_index { |line, i| fa_wiersz(x, line, i + 1) }
        platnosc(x)
      end
    end

    def totals(x)
      case treatment
      when :pl_23
        x.P_13_1(money(invoice.net))
        x.P_14_1(money(invoice.vat))
        x.P_14_1W(money(invoice.vat_pln)) if foreign_currency?
      when :non_eu
        x.P_13_8(money(invoice.net))
      when :eu_reverse_charge
        x.P_13_9(money(invoice.net))
      end
    end

    def adnotacje(x)
      x.Adnotacje do
        x.P_16(2)  # not cash accounting (metoda kasowa)
        x.P_17(2)  # not self-billing
        x.P_18(treatment == :eu_reverse_charge ? 1 : 2) # "odwrotne obciążenie"
        x.P_18A(2) # no split payment
        x.Zwolnienie { x.P_19N(1) }             # no VAT exemption
        x.NoweSrodkiTransportu { x.P_22N(1) }   # no new means of transport
        x.P_23(2)  # not a simplified triangular procedure
        x.PMarzy { x.P_PMarzyN(1) }             # no margin scheme
      end
    end

    # FA(3) has no field for the date of the NBP table, so it goes in a
    # key/value note next to the rate itself (which sits on every line).
    def exchange_rate_note(x)
      return unless treatment == :pl_23 && foreign_currency?

      table = invoice.exchange_rate_date ? " (kurs średni NBP z dnia #{date(invoice.exchange_rate_date)})" : ""
      x.DodatkowyOpis do
        x.Klucz("Kurs waluty")
        x.Wartosc("1 #{invoice.currency.to_s.upcase} = #{rate(invoice.exchange_rate)} PLN#{table}")
      end
    end

    def fa_wiersz(x, line, number)
      x.FaWiersz do
        x.NrWierszaFa(number)
        x.P_7(text(line.name, 512))
        x.P_8A(UNIT)
        x.P_8B(1)
        x.P_9A(money(line.net))
        x.P_11(money(line.net))
        x.P_12(LINE_RATE.fetch(treatment))
        x.KursWaluty(rate(invoice.exchange_rate)) if treatment == :pl_23 && foreign_currency?
      end
    end

    def platnosc(x)
      return unless invoice.paid_on

      x.Platnosc do
        x.Zaplacono(1)
        x.DataZaplaty(date(invoice.paid_on))
        x.FormaPlatnosci(CARD)
      end
    end

    def date(value) = value.to_date.iso8601

    # TKwotowy: up to 2 decimals, written with exactly two (exact, no Float).
    def money(value)
      amount = BigDecimal(value.to_s).round(2, BigDecimal::ROUND_HALF_UP)
      whole, fraction = amount.abs.to_s("F").split(".")
      "#{'-' if amount.negative?}#{whole}.#{fraction.to_s.ljust(2, '0')}"
    end

    # TIlosci: up to 6 decimals.
    def rate(value)
      BigDecimal(value.to_s).round(6).to_s("F").sub(/\.0\z/, "")
    end

    # TZnakowy: a non-empty token of at most 256 (or 512) characters.
    def text(value, limit = 256)
      value.to_s.squish.truncate(limit, omission: "")
    end
  end
end
