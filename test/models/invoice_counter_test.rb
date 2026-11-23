require "test_helper"

class InvoiceCounterTest < ActiveSupport::TestCase
  test "numbers run from 0001 within a month and start again the next" do
    assert_equal "FV/2026/11/0001", InvoiceCounter.next_number!(Date.new(2026, 11, 1))
    assert_equal "FV/2026/11/0002", InvoiceCounter.next_number!(Date.new(2026, 11, 30))
    assert_equal "FV/2026/12/0001", InvoiceCounter.next_number!(Date.new(2026, 12, 3))
  end

  test "the prefix comes from INVOICE_NUMBER_PREFIX" do
    with_env("INVOICE_NUMBER_PREFIX" => "FLS") do
      assert_equal "FLS/2026/11/0001", InvoiceCounter.next_number!(Date.new(2026, 11, 5))
    end
  end
end
