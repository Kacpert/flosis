require "test_helper"
require "webmock/minitest"

class Ksef::HttpTest < ActiveSupport::TestCase
  BASE = "https://api-test.ksef.mf.gov.pl/v2"

  setup { @http = Ksef::Http.new(BASE) }

  test "sends JSON with a bearer token and asks for problem-details errors" do
    stub = stub_request(:post, "#{BASE}/sessions/online")
      .with(headers: { "Authorization" => "Bearer access-1", "Content-Type" => "application/json", "X-Error-Format" => "problem-details" },
            body: { a: 1 }.to_json)
      .to_return(status: 201, body: { referenceNumber: "S-1" }.to_json)

    assert_equal({ "referenceNumber" => "S-1" }, @http.post_json("/sessions/online", { a: 1 }, token: "access-1"))
    assert_requested stub
  end

  test "an empty 204 is nil" do
    stub_request(:post, "#{BASE}/sessions/online/S-1/close").to_return(status: 204, body: "")

    assert_nil @http.post_json("/sessions/online/S-1/close", nil, token: "t")
  end

  test "problem details: KSeF's code and description" do
    stub_request(:post, "#{BASE}/sessions/online").to_return(status: 400, body: {
      title: "Bad Request", status: 400, detail: "Validation failed",
      errors: [ { code: 21405, description: "Błąd walidacji danych wejściowych.", details: [ "formCode is invalid" ] } ]
    }.to_json)

    error = assert_raises(Ksef::ApiError) { @http.post_json("/sessions/online", {}, token: "secret-access") }
    assert_equal [ 400, 21405 ], [ error.http_status, error.code ]
    assert_equal "KSeF 400: Błąd walidacji danych wejściowych.: formCode is invalid (code 21405)", error.message
    refute_includes error.message, "secret-access"
  end

  test "the older exception shape" do
    stub_request(:get, "#{BASE}/sessions/S/invoices/I").to_return(status: 400, body: {
      exception: { exceptionDetailList: [ { exceptionCode: 21470, exceptionDescription: "Nieznany klucz.", details: [] } ] }
    }.to_json)

    error = assert_raises(Ksef::ApiError) { @http.get("/sessions/S/invoices/I") }
    assert_equal 21470, error.code
    assert_includes error.message, "Nieznany klucz."
  end

  test "429 and bodies that aren't JSON still give a short message" do
    stub_request(:get, "#{BASE}/a").to_return(status: 429, body: { status: { code: 429, description: "Too Many Requests", details: [ "Retry in 10 s" ] } }.to_json)
    stub_request(:get, "#{BASE}/b").to_return(status: 502, body: "<html>Bad gateway</html>")

    assert_equal "KSeF 429: Too Many Requests: Retry in 10 s (code 429)", assert_raises(Ksef::ApiError) { @http.get("/a") }.message
    assert_equal "KSeF 502: HTTP 502", assert_raises(Ksef::ApiError) { @http.get("/b") }.message
  end

  test "network failures become TransportError" do
    stub_request(:post, "#{BASE}/auth/challenge").to_timeout

    error = assert_raises(Ksef::TransportError) { @http.post_json("/auth/challenge") }
    assert_match(/KSeF unreachable/, error.message)
  end
end
