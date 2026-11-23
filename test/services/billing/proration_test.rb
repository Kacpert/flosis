require "test_helper"

class Billing::ProrationTest < ActiveSupport::TestCase
  test "joining on 20 Nov with a $300 plan pays 11 of 30 days: $110" do
    date = Date.new(2026, 11, 20)
    assert_equal 11, Billing::Proration.days_left(date)
    assert_equal BigDecimal("110.00"), Billing::Proration.amount(300, date)
    assert_equal date..Date.new(2026, 11, 30), Billing::Proration.period(date)
  end

  test "activating Starter on 22 Nov charges $60 for 22–30 Nov" do
    assert_equal BigDecimal("60.00"), Billing::Proration.amount(BigDecimal("200"), Date.new(2026, 11, 22))
  end

  test "an upgrade from $300 to $600 on day 16 of 30 charges $150" do
    assert_equal BigDecimal("150.00"), Billing::Proration.amount(600 - 300, Date.new(2026, 11, 16))
  end

  test "the 1st pays the whole month and the last day one day" do
    assert_equal BigDecimal("300.00"), Billing::Proration.amount(300, Date.new(2026, 12, 1))
    assert_equal BigDecimal("9.68"), Billing::Proration.amount(300, Date.new(2026, 12, 31))
  end

  test "the period reads as the design writes it" do
    assert_equal "22–30 Nov", Billing::Proration.label(Date.new(2026, 11, 22)..Date.new(2026, 11, 30))
    assert_equal "30 Nov", Billing::Proration.label(Date.new(2026, 11, 30)..Date.new(2026, 11, 30))
  end
end
