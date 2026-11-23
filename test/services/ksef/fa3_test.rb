require "test_helper"
require_relative "ksef_test_support"

class Ksef::Fa3Test < ActiveSupport::TestCase
  include KsefTestSupport

  GENERATED_AT = Time.utc(2026, 11, 23, 10, 15, 0)

  def xml_for(invoice)
    Ksef::Fa3.new(invoice, generated_at: GENERATED_AT).to_xml
  end

  def doc_for(invoice) = Nokogiri::XML(xml_for(invoice))

  def value(doc, path) = doc.at_xpath(path, FA3_NS)&.text
  def values(doc, path) = doc.xpath(path, FA3_NS).map(&:text)

  test "every VAT treatment produces XML valid against the FA(3) schema" do
    Ksef::Fa3::TREATMENTS.each do |treatment|
      assert_empty schema_errors(xml_for(sample_invoice(treatment))), "#{treatment} XML is not valid FA(3)"
    end
  end

  test "the header names the FA(3) form, its variant, when it was made and by what" do
    doc = doc_for(sample_invoice)

    form = doc.at_xpath("//fa:Naglowek/fa:KodFormularza", FA3_NS)
    assert_equal "FA", form.text
    assert_equal "FA (3)", form["kodSystemowy"]
    assert_equal "1-0E", form["wersjaSchemy"]
    assert_equal "3", value(doc, "//fa:Naglowek/fa:WariantFormularza")
    assert_equal "2026-11-23T10:15:00Z", value(doc, "//fa:Naglowek/fa:DataWytworzeniaFa")
    assert_equal "Flosis", value(doc, "//fa:Naglowek/fa:SystemInfo")
  end

  test "Polish 23% VAT: USD amounts, VAT in PLN, the NBP rate on each line" do
    doc = doc_for(sample_invoice(:pl_23))

    assert_equal SELLER_NIP, value(doc, "//fa:Podmiot1/fa:DaneIdentyfikacyjne/fa:NIP")
    assert_nil doc.at_xpath("//fa:Podmiot1/fa:PrefiksPodatnika", FA3_NS)
    assert_equal BUYER_NIP, value(doc, "//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:NIP")
    assert_equal "PL", value(doc, "//fa:Podmiot2/fa:Adres/fa:KodKraju")
    assert_equal %w[2 2], [ value(doc, "//fa:Podmiot2/fa:JST"), value(doc, "//fa:Podmiot2/fa:GV") ]

    assert_equal "USD", value(doc, "//fa:Fa/fa:KodWaluty")
    assert_equal "2026-11-23", value(doc, "//fa:Fa/fa:P_1")
    assert_equal "FV/2026/11/0004", value(doc, "//fa:Fa/fa:P_2")
    assert_equal "100.10", value(doc, "//fa:Fa/fa:P_13_1")
    assert_equal "23.02", value(doc, "//fa:Fa/fa:P_14_1")
    assert_equal "92.36", value(doc, "//fa:Fa/fa:P_14_1W")
    assert_equal "123.12", value(doc, "//fa:Fa/fa:P_15")
    assert_nil doc.at_xpath("//fa:Fa/fa:P_13_8 | //fa:Fa/fa:P_13_9", FA3_NS)
    assert_equal "2", value(doc, "//fa:Adnotacje/fa:P_18")

    assert_equal %w[23 23], values(doc, "//fa:FaWiersz/fa:P_12")
    assert_equal %w[4.0123 4.0123], values(doc, "//fa:FaWiersz/fa:KursWaluty")
    assert_equal "1 USD = 4.0123 PLN (kurs średni NBP z dnia 2026-11-20)", value(doc, "//fa:DodatkowyOpis/fa:Wartosc")
  end

  test "EU reverse charge: art. 100 ust. 1 pkt 4 total, np II lines, odwrotne obciążenie, buyer's VAT-UE number" do
    doc = doc_for(sample_invoice(:eu_reverse_charge))

    assert_equal "PL", value(doc, "//fa:Podmiot1/fa:PrefiksPodatnika")
    assert_equal "DE", value(doc, "//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:KodUE")
    assert_equal "123456789", value(doc, "//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:NrVatUE")
    assert_equal "DE", value(doc, "//fa:Podmiot2/fa:Adres/fa:KodKraju")

    assert_equal "100.10", value(doc, "//fa:Fa/fa:P_13_9")
    assert_equal "100.10", value(doc, "//fa:Fa/fa:P_15")
    assert_nil doc.at_xpath("//fa:Fa/fa:P_13_1 | //fa:Fa/fa:P_14_1W | //fa:FaWiersz/fa:KursWaluty | //fa:DodatkowyOpis", FA3_NS)
    assert_equal "1", value(doc, "//fa:Adnotacje/fa:P_18")
    assert_equal [ "np II", "np II" ], values(doc, "//fa:FaWiersz/fa:P_12")
  end

  test "outside the EU: sale outside Poland, np I lines, BrakID when the buyer has no tax id" do
    doc = doc_for(sample_invoice(:non_eu))

    assert_equal "1", value(doc, "//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:BrakID")
    assert_equal "US", value(doc, "//fa:Podmiot2/fa:Adres/fa:KodKraju")
    assert_equal "100.10", value(doc, "//fa:Fa/fa:P_13_8")
    assert_equal "100.10", value(doc, "//fa:Fa/fa:P_15")
    assert_nil doc.at_xpath("//fa:Fa/fa:P_13_1 | //fa:Fa/fa:P_13_9 | //fa:Podmiot1/fa:PrefiksPodatnika", FA3_NS)
    assert_equal "2", value(doc, "//fa:Adnotacje/fa:P_18")
    assert_equal [ "np I", "np I" ], values(doc, "//fa:FaWiersz/fa:P_12")
  end

  test "outside the EU with a tax id: KodKraju + NrID" do
    buyer = buyer_for(:non_eu).with(tax_id: "12-3456789")
    xml = xml_for(sample_invoice(:non_eu, buyer: buyer))
    doc = Nokogiri::XML(xml)

    assert_empty schema_errors(xml)
    assert_equal "US", value(doc, "//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:KodKraju")
    assert_equal "12-3456789", value(doc, "//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:NrID")
    assert_nil doc.at_xpath("//fa:Podmiot2/fa:DaneIdentyfikacyjne/fa:BrakID", FA3_NS)
  end

  test "lines: name, one unit, unit net price, net value" do
    doc = doc_for(sample_invoice)

    assert_equal %w[1 2], values(doc, "//fa:FaWiersz/fa:NrWierszaFa")
    assert_equal [ "Flosis Team plan, November 2026", "AI usage" ], values(doc, "//fa:FaWiersz/fa:P_7")
    assert_equal [ "szt.", "szt." ], values(doc, "//fa:FaWiersz/fa:P_8A")
    assert_equal %w[1 1], values(doc, "//fa:FaWiersz/fa:P_8B")
    assert_equal %w[80.00 20.10], values(doc, "//fa:FaWiersz/fa:P_9A")
    assert_equal %w[80.00 20.10], values(doc, "//fa:FaWiersz/fa:P_11")
  end

  test "paid by card in full on paid_on" do
    doc = doc_for(sample_invoice(paid_on: Date.new(2026, 11, 22)))

    assert_equal "1", value(doc, "//fa:Platnosc/fa:Zaplacono")
    assert_equal "2026-11-22", value(doc, "//fa:Platnosc/fa:DataZaplaty")
    assert_equal "2", value(doc, "//fa:Platnosc/fa:FormaPlatnosci")
  end

  test "the Adnotacje carry the 'no' defaults" do
    doc = doc_for(sample_invoice)

    assert_equal %w[2 2 2 2], %w[P_16 P_17 P_18A P_23].map { |field| value(doc, "//fa:Adnotacje/fa:#{field}") }
    assert_equal "1", value(doc, "//fa:Adnotacje/fa:Zwolnienie/fa:P_19N")
    assert_equal "1", value(doc, "//fa:Adnotacje/fa:NoweSrodkiTransportu/fa:P_22N")
    assert_equal "1", value(doc, "//fa:Adnotacje/fa:PMarzy/fa:P_PMarzyN")
    assert_equal "VAT", value(doc, "//fa:Fa/fa:RodzajFaktury")
  end

  test "P_6 only when the sale date differs from the issue date" do
    assert_nil doc_for(sample_invoice).at_xpath("//fa:Fa/fa:P_6", FA3_NS)

    doc = doc_for(sample_invoice(sold_on: Date.new(2026, 11, 20)))
    assert_equal "2026-11-20", value(doc, "//fa:Fa/fa:P_6")
  end

  test "amounts are written exactly with two decimals" do
    line = Ksef::Line.new(name: "x", net: BigDecimal("0.1"), vat_rate: nil, vat: BigDecimal("0"), gross: BigDecimal("0.1"))
    invoice = sample_invoice(:non_eu, lines: [ line ], net: BigDecimal("0.1"), vat: BigDecimal("0"), gross: BigDecimal("1234567890123.455"))
    doc = doc_for(invoice)

    assert_equal "0.10", value(doc, "//fa:Fa/fa:P_13_8")
    assert_equal "1234567890123.46", value(doc, "//fa:Fa/fa:P_15")
  end

  test "a Greek VAT number keeps its EL prefix; a bare number takes it from the country" do
    greek = buyer_for(:eu_reverse_charge).with(eu_vat_number: "EL 123 456 789", country_code: "GR")
    doc = doc_for(sample_invoice(:eu_reverse_charge, buyer: greek))
    assert_equal %w[EL 123456789], [ value(doc, "//fa:KodUE"), value(doc, "//fa:NrVatUE") ]

    bare = buyer_for(:eu_reverse_charge).with(eu_vat_number: "123456789", country_code: "GR")
    doc = doc_for(sample_invoice(:eu_reverse_charge, buyer: bare))
    assert_equal %w[EL 123456789], [ value(doc, "//fa:KodUE"), value(doc, "//fa:NrVatUE") ]
  end

  test "refuses invoices it cannot express" do
    assert_raises(ArgumentError) { Ksef::Fa3.new(sample_invoice(vat_treatment: :oss)) }
    assert_raises(ArgumentError) { Ksef::Fa3.new(sample_invoice(:eu_reverse_charge, buyer: buyer_for(:eu_reverse_charge).with(eu_vat_number: nil))) }
    assert_raises(ArgumentError) { Ksef::Fa3.new(sample_invoice(:pl_23, exchange_rate: nil)) }
    assert_raises(ArgumentError) { Ksef::Fa3.new(sample_invoice(:pl_23, seller: seller.with(nip: "5265877636"))) }
    assert_raises(ArgumentError) { Ksef::Fa3.new(sample_invoice(:pl_23, buyer: buyer_for(:pl_23).with(nip: "1234567890"))) }
  end

  test "UTF-8 without a byte-order mark" do
    xml = xml_for(sample_invoice)

    assert_equal Encoding::UTF_8, xml.encoding
    assert xml.start_with?('<?xml version="1.0" encoding="UTF-8"?>')
    assert_includes xml, "Kraków"
  end
end
