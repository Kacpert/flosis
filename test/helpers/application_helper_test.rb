require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "format_money without a currency keeps the dollar style" do
    assert_equal "$150.00", format_money(15_000)
    assert_equal "$0.00", format_money(nil)
  end

  test "format_money with a currency appends a delimited amount and code" do
    assert_equal "150.00 USD", format_money(15_000, "USD")
    assert_equal "1,234.50 USD", format_money(123_450, "USD")
  end

  test "format_money with a currency treats nil cents as zero" do
    assert_equal "0.00 USD", format_money(nil, "USD")
  end
end
