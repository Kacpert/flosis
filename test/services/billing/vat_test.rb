require "test_helper"

class Billing::VatTest < ActiveSupport::TestCase
  test "a Polish company pays 23% VAT" do
    vat = Billing::Vat.for("PL")
    assert_equal :pl_23, vat.kind
    assert_equal BigDecimal("46.00"), vat.vat_on(BigDecimal("200"))
    assert_equal "NIP", vat.number_label
    assert_equal "Polish company: invoices carry 23% VAT.", vat.note
    assert vat.number_required?
  end

  test "an EU business gets a reverse charge" do
    vat = Billing::Vat.for("DE")
    assert_equal :eu_reverse_charge, vat.kind
    assert_equal BigDecimal("0"), vat.vat_on(BigDecimal("200"))
    assert_equal "EU VAT NUMBER", vat.number_label
    assert_equal "EU business with a valid EU VAT number: reverse charge, no Polish VAT.", vat.note
    assert vat.number_required?
  end

  test "outside the EU the invoice is not subject to Polish VAT, and the tax id is optional" do
    vat = Billing::Vat.for("US")
    assert_equal :non_eu, vat.kind
    assert_equal BigDecimal("0"), vat.vat_on(BigDecimal("100"))
    assert_equal "TAX ID (OPTIONAL)", vat.number_label
    assert_equal "Outside the EU: invoices are not subject to Polish VAT.", vat.note
    assert_not vat.number_required?
  end

  test "Greece is in the EU, Norway and the UK are not" do
    assert_equal :eu_reverse_charge, Billing::Vat.for("GR").kind
    assert_equal :non_eu, Billing::Vat.for("NO").kind
    assert_equal :non_eu, Billing::Vat.for("gb").kind
  end

  test "a gross amount and its words" do
    vat = Billing::Vat.for("PL")
    assert_equal BigDecimal("246.00"), vat.gross(BigDecimal("200"))
    assert_equal "23% VAT", vat.short_label
    assert_equal "reverse charge", Billing::Vat.for("DE").short_label
    assert_equal "no Polish VAT", Billing::Vat.for("US").short_label
  end
end
