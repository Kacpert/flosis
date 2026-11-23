require "test_helper"
require "webmock/minitest"

class NbpRateTest < ActiveSupport::TestCase
  test "the last working day's rate before the date" do
    stub_request(:get, "https://api.nbp.pl/api/exchangerates/rates/a/usd/2026-10-22/2026-10-31/?format=json")
      .to_return(body: { table: "A", code: "USD", rates: [
        { no: "209/A/NBP/2026", effectiveDate: "2026-10-29", mid: 3.6401 },
        { no: "210/A/NBP/2026", effectiveDate: "2026-10-30", mid: 3.6512 }
      ] }.to_json)
    rate = NbpRate.usd_before(Date.new(2026, 11, 1))
    assert_equal BigDecimal("3.6512"), rate.mid
    assert_equal Date.new(2026, 10, 30), rate.date
    assert_equal "210/A/NBP/2026", rate.table
  end

  test "NBP down or empty is Unavailable" do
    stub_request(:get, %r{api.nbp.pl}).to_return(status: 404, body: "404 NotFound")
    assert_raises(NbpRate::Unavailable) { NbpRate.usd_before(Date.new(2026, 11, 1)) }
    stub_request(:get, %r{api.nbp.pl}).to_timeout
    assert_raises(NbpRate::Unavailable) { NbpRate.usd_before(Date.new(2026, 11, 1)) }
  end
end
