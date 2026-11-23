require "test_helper"
require "webmock/minitest"

class Billing::ViesTest < ActiveSupport::TestCase
  test "a valid German VAT number, with or without its prefix" do
    stub_request(:get, "https://ec.europa.eu/taxation_customs/vies/rest-api/ms/DE/vat/123456789")
      .to_return(body: { isValid: true, name: "Acme GmbH", userError: "VALID" }.to_json)
    result = Billing::Vies.check("de", "DE 123 456 789")
    assert result.valid?
    assert_equal "Acme GmbH", result.name
    assert_not result.unavailable?
  end

  test "an invalid number is not valid and VIES was reachable" do
    stub_request(:get, %r{/ms/FR/vat/}).to_return(body: { isValid: false, userError: "INVALID" }.to_json)
    result = Billing::Vies.check("FR", "FR00000000000")
    assert_not result.valid?
    assert_not result.unavailable?
  end

  test "Greece is EL in VIES" do
    stub = stub_request(:get, %r{/ms/EL/vat/123456789}).to_return(body: { isValid: true, name: "---" }.to_json)
    assert Billing::Vies.check("GR", "EL123456789").valid?
    assert_requested stub
  end

  test "a member state that is down is unavailable, not invalid" do
    stub_request(:get, %r{/ms/IT/vat/}).to_return(body: { isValid: false, userError: "MS_UNAVAILABLE" }.to_json)
    assert Billing::Vies.check("IT", "12345678901").unavailable?
    stub_request(:get, %r{/ms/ES/vat/}).to_timeout
    assert Billing::Vies.check("ES", "B12345678").unavailable?
  end
end
