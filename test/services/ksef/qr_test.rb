require "test_helper"

class Ksef::QrTest < ActiveSupport::TestCase
  # SHA-256("abc") is the standard test vector; its Base64URL form exercises
  # both substitutions (+ -> -, / -> _) and the dropped "=" padding.
  ABC_HASH = "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"

  test "KOD I: host/invoice/NIP/DD-MM-YYYY/SHA-256 of the XML bytes in Base64URL" do
    url = Ksef::Qr.invoice_url(seller_nip: "1111111111", issued_on: Date.new(2026, 2, 1), xml: "abc", environment: :test)

    assert_equal "https://qr-test.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/#{ABC_HASH}", url
  end

  test "hashes the exact UTF-8 bytes" do
    xml = "<a>Kraków</a>"

    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(xml.encode("UTF-8").b), padding: false), Ksef::Qr.xml_hash(xml)
    refute_equal Ksef::Qr.xml_hash(xml), Ksef::Qr.xml_hash("#{xml}\n")
  end

  test "one host per environment" do
    hosts = %i[test demo production].map do |environment|
      Ksef::Qr.invoice_url(seller_nip: "1111111111", issued_on: Date.new(2026, 2, 1), xml: "abc", environment: environment)[%r{\Ahttps://[^/]+}]
    end

    assert_equal %w[https://qr-test.ksef.mf.gov.pl https://qr-demo.ksef.mf.gov.pl https://qr.ksef.mf.gov.pl], hosts
  end

  test "Ksef.qr_url follows KSEF_ENV" do
    with_env("KSEF_ENV" => "production") do
      assert_equal "https://qr.ksef.mf.gov.pl/invoice/5265877635/23-11-2026/#{ABC_HASH}",
                   Ksef.qr_url(seller_nip: "5265877635", issued_on: Date.new(2026, 11, 23), xml: "abc")
    end
  end

  test "Ksef.environment: test by default, demo/production when asked, loud on a typo" do
    with_env("KSEF_ENV" => nil) { assert_equal :test, Ksef.environment }
    with_env("KSEF_ENV" => "demo") { assert_equal :demo, Ksef.environment }
    with_env("KSEF_ENV" => "Production") { assert_equal :production, Ksef.environment }
    with_env("KSEF_ENV" => "prd") { assert_raises(Ksef::ConfigurationError) { Ksef.environment } }
  end

  test "API base URL per environment" do
    assert_equal "https://api-test.ksef.mf.gov.pl/v2", Ksef.api_url(:test)
    assert_equal "https://api-demo.ksef.mf.gov.pl/v2", Ksef.api_url(:demo)
    assert_equal "https://api.ksef.mf.gov.pl/v2", Ksef.api_url(:production)
  end

  test "NIP checksum" do
    assert Ksef::Nip.valid?("5265877635")
    assert Ksef::Nip.valid?("7980332920")
    refute Ksef::Nip.valid?("5265877636")
    refute Ksef::Nip.valid?("0265877635")
    refute Ksef::Nip.valid?("526587763")
    20.times { assert Ksef::Nip.valid?(Ksef::Nip.random) }
  end

  test "SendResult splits its SESSION/INVOICE reference" do
    result = Ksef::SendResult.new(status: :pending, reference_number: "20261123-SO-1/20261123-EE-2")

    assert result.pending?
    assert_equal "20261123-SO-1", result.session_reference
    assert_equal "20261123-EE-2", result.invoice_reference
    assert_nil Ksef::SendResult.new(status: :failed, error: "x").session_reference
  end
end
