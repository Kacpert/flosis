require "test_helper"

class InvoiceCounterTest < ActiveSupport::TestCase
  test "numbers run from 001 within a month, in the company's format, and start again the next" do
    assert_equal "FV/F/001/11/2026", InvoiceCounter.next_number!(Date.new(2026, 11, 1))
    assert_equal "FV/F/002/11/2026", InvoiceCounter.next_number!(Date.new(2026, 11, 30))
    assert_equal "FV/F/001/12/2026", InvoiceCounter.next_number!(Date.new(2026, 12, 3))
  end

  test "the prefix comes from INVOICE_NUMBER_PREFIX" do
    with_env("INVOICE_NUMBER_PREFIX" => "FV") do
      InvoiceCounter.ensure!(Date.new(2026, 11, 5))
      assert_equal "FV/001/11/2026", InvoiceCounter.next_number!(Date.new(2026, 11, 5))
    end
  end
end
