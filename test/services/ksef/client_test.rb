require "test_helper"
require "webmock/minitest"
require_relative "ksef_test_support"

class Ksef::ClientTest < ActiveSupport::TestCase
  include KsefTestSupport

  BASE = "https://api-test.ksef.mf.gov.pl/v2"
  KSEF_TOKEN = "20261123-EC-0000000000-0000000000-00|nip-5265877635|feedface"
  CHALLENGE = "20261123-CR-4C7B19F001-E1B926D89C-0A"
  CHALLENGE_MS = 1_795_472_195_999
  SESSION = "20261123-SO-4CEAEDC000-332A218498-45"
  INVOICE = "20261123-EE-4CEAF2A000-DBFD66C62D-AD"
  KSEF_NUMBER = "5265877635-20261123-A48F39400000-1B"

  setup do
    Ksef::Auth.reset!
    Ksef::PublicKeys.reset!
    @xml = Ksef::Fa3.new(sample_invoice).to_xml
    @sent = {}
    @now = Time.now
    stub_public_keys
  end

  teardown do
    Ksef::Auth.reset!
    Ksef::PublicKeys.reset!
  end

  def client(**options)
    credentials = options.key?(:certificate) ? {} : { ksef_token: KSEF_TOKEN }
    Ksef::Client.new(environment: :test, nip: SELLER_NIP, sleeper: ->(_seconds) { }, clock: -> { @now += 1 },
                     **credentials, **options)
  end

  def public_key_id(usage) = "#{usage.ljust(43, 'x')[0, 43]}="

  def stub_public_keys
    entries = %w[KsefTokenEncryption SymmetricKeyEncryption].map do |usage|
      { certificate: Base64.strict_encode64(mf_certificate.to_der), certificateId: "id", publicKeyId: public_key_id(usage),
        validFrom: (Time.now - 86_400).iso8601, validTo: (Time.now + 86_400).iso8601, usage: [ usage ] }
    end
    stub_request(:get, "#{BASE}/security/public-key-certificates").to_return(status: 200, body: entries.to_json)
  end

  def stub_login(status_codes: [ 100, 200 ], access: "access-jwt")
    stub_request(:post, "#{BASE}/auth/challenge")
      .to_return(status: 200, body: { challenge: CHALLENGE, timestamp: "2026-11-23T22:16:35.9998811+00:00", timestampMs: CHALLENGE_MS, clientIp: "1.2.3.4" }.to_json)
    stub_request(:post, "#{BASE}/auth/ksef-token").to_return do |request|
      body = JSON.parse(request.body)
      @sent[:token_login] = body.merge("decrypted" => oaep_decrypt(Base64.decode64(body["encryptedToken"])))
      { status: 202, body: { referenceNumber: "AUTH-1", authenticationToken: { token: "auth-jwt", validUntil: (Time.now + 600).iso8601 } }.to_json }
    end
    stub_request(:get, "#{BASE}/auth/AUTH-1").with(headers: { "Authorization" => "Bearer auth-jwt" })
      .to_return(*status_codes.map { |code| { status: 200, body: { status: { code: code, description: "status #{code}", details: [ "detail #{code}" ] } }.to_json } })
    stub_request(:post, "#{BASE}/auth/token/redeem").with(headers: { "Authorization" => "Bearer auth-jwt" })
      .to_return(status: 200, body: {
        accessToken: { token: access, validUntil: (Time.now + 900).iso8601 },
        refreshToken: { token: "refresh-jwt", validUntil: (Time.now + 7 * 86_400).iso8601 }
      }.to_json)
  end

  def stub_session(access: "access-jwt")
    stub_request(:post, "#{BASE}/sessions/online").with(headers: { "Authorization" => "Bearer #{access}" }).to_return do |request|
      body = JSON.parse(request.body)
      @sent[:session] = body
      @sent[:key] = oaep_decrypt(Base64.decode64(body.dig("encryption", "encryptedSymmetricKey")))
      @sent[:iv] = Base64.decode64(body.dig("encryption", "initializationVector"))
      { status: 201, body: { referenceNumber: SESSION, validUntil: (Time.now + 43_200).iso8601 }.to_json }
    end
    stub_request(:post, "#{BASE}/sessions/online/#{SESSION}/invoices").to_return do |request|
      body = JSON.parse(request.body)
      decipher = OpenSSL::Cipher.new("aes-256-cbc").tap(&:decrypt)
      decipher.key = @sent[:key]
      decipher.iv = @sent[:iv]
      @sent[:invoice] = body.merge("decrypted" => decipher.update(Base64.decode64(body["encryptedInvoiceContent"])) + decipher.final)
      { status: 202, body: { referenceNumber: INVOICE }.to_json }
    end
    @close = stub_request(:post, "#{BASE}/sessions/online/#{SESSION}/close").to_return(status: 204)
  end

  def stub_status(*statuses)
    stub_request(:get, "#{BASE}/sessions/#{SESSION}/invoices/#{INVOICE}").to_return(*statuses.map { |status|
      { status: 200, body: { ordinalNumber: 1, referenceNumber: INVOICE, invoiceHash: "h", invoicingDate: Time.now.iso8601 }.merge(status).to_json }
    })
  end

  def accepted = { ksefNumber: KSEF_NUMBER, status: { code: 200, description: "Sukces" } }
  def processing = { status: { code: 150, description: "Trwa przetwarzanie" } }

  test "token login → session → send → close → status: accepted with the KSeF number" do
    stub_login
    stub_session
    stub_status(processing, accepted)

    result = client.send_invoice(@xml)

    assert_equal :accepted, result.status
    assert_equal KSEF_NUMBER, result.ksef_number
    assert_equal "#{SESSION}/#{INVOICE}", result.reference_number
    assert_nil result.error
    assert_requested @close
  end

  test "the login secret is '<KSeF token>|<challenge ms>' under the KsefTokenEncryption key" do
    stub_login
    stub_session
    stub_status(accepted)

    client.send_invoice(@xml)

    login = @sent[:token_login]
    assert_equal "#{KSEF_TOKEN}|#{CHALLENGE_MS}", login["decrypted"]
    assert_equal CHALLENGE, login["challenge"]
    assert_equal({ "type" => "Nip", "value" => SELLER_NIP }, login["contextIdentifier"])
    assert_equal public_key_id("KsefTokenEncryption"), login["publicKeyId"]
  end

  test "the session gets a fresh AES key under the SymmetricKeyEncryption key; the invoice goes encrypted with matching hashes" do
    stub_login
    stub_session
    stub_status(accepted)

    client.send_invoice(@xml)

    session = @sent[:session]
    assert_equal({ "systemCode" => "FA (3)", "schemaVersion" => "1-0E", "value" => "FA" }, session["formCode"])
    assert_equal public_key_id("SymmetricKeyEncryption"), session.dig("encryption", "publicKeyId")
    assert_equal [ 32, 16 ], [ @sent[:key].bytesize, @sent[:iv].bytesize ]

    invoice = @sent[:invoice]
    encrypted = Base64.decode64(invoice["encryptedInvoiceContent"])
    assert_equal @xml.b, invoice["decrypted"]
    assert_equal Ksef::Crypto.sha256_base64(@xml), invoice["invoiceHash"]
    assert_equal @xml.bytesize, invoice["invoiceSize"]
    assert_equal Ksef::Crypto.sha256_base64(encrypted), invoice["encryptedInvoiceHash"]
    assert_equal encrypted.bytesize, invoice["encryptedInvoiceSize"]
  end

  test "rejected: KSeF's description, details and code, no secrets" do
    stub_login
    stub_session
    stub_status(processing, { status: { code: 450, description: "Błąd weryfikacji semantyki dokumentu faktury", details: [ "P_1 later than acceptance date" ] } })

    result = client.send_invoice(@xml)

    assert_equal :rejected, result.status
    assert_nil result.ksef_number
    assert_equal "#{SESSION}/#{INVOICE}", result.reference_number
    assert_equal "Rejected by KSeF: Błąd weryfikacji semantyki dokumentu faktury: P_1 later than acceptance date (code 450)", result.error
  end

  test "pending when KSeF hasn't decided within the wait; invoice_status picks it up later" do
    stub_login
    stub_session
    stub_status(*Array.new(30) { processing }, accepted)

    result = client(status_timeout: 5).send_invoice(@xml)

    assert_equal :pending, result.status
    assert_equal "#{SESSION}/#{INVOICE}", result.reference_number

    later = client.invoice_status(result.session_reference, result.invoice_reference)
    assert_equal :pending, later.status
    stub_status(accepted)
    assert_equal [ :accepted, KSEF_NUMBER ], client.invoice_status(SESSION, INVOICE).then { |r| [ r.status, r.ksef_number ] }
  end

  test "a duplicate of an invoice already in KSeF counts as accepted under the original number" do
    stub_login
    stub_session
    stub_status({ status: { code: 440, description: "Duplikat faktury", extensions: { originalKsefNumber: KSEF_NUMBER, originalSessionReferenceNumber: "S-0" } } })

    result = client.send_invoice(@xml)

    assert_equal [ :accepted, KSEF_NUMBER ], [ result.status, result.ksef_number ]
    assert_match(/code 440/, result.error)
  end

  test "KSeF giving up for its own reasons is failed (send again)" do
    stub_login
    stub_session
    stub_status({ status: { code: 550, description: "Operacja została anulowana przez system" } })

    result = client.send_invoice(@xml)

    assert_equal :failed, result.status
    assert_match(/code 550/, result.error)
  end

  test "failed when KSeF can't be reached" do
    stub_request(:post, "#{BASE}/auth/challenge").to_timeout

    result = client.send_invoice(@xml)

    assert_equal :failed, result.status
    assert_nil result.reference_number
    assert_equal "KSeF unreachable (OpenTimeout)", result.error
  end

  test "failed when the login is refused, without leaking the token" do
    stub_login(status_codes: [ 100, 450 ])

    result = client.send_invoice(@xml)

    assert_equal :failed, result.status
    assert_equal "KSeF refused the login: status 450: detail 450 (code 450)", result.error
    refute_includes result.error, KSEF_TOKEN
  end

  test "failed with KSeF's code when it refuses to open a session" do
    stub_login
    stub_request(:post, "#{BASE}/sessions/online").to_return(status: 400, body: {
      title: "Bad Request", status: 400, errors: [ { code: 21405, description: "Błąd walidacji danych wejściowych." } ]
    }.to_json)

    result = client.send_invoice(@xml)

    assert_equal :failed, result.status
    assert_equal "KSeF 400: Błąd walidacji danych wejściowych. (code 21405)", result.error
    %w[access-jwt auth-jwt refresh-jwt].each { |secret| refute_includes result.error, secret }
  end

  test "a 401 logs in again once and carries on" do
    stub_login(access: "access-2")
    stub_session(access: "access-2")
    stub_status(accepted)
    stub_request(:post, "#{BASE}/auth/token/refresh").to_return(status: 401, body: { title: "Unauthorized", status: 401, detail: "expired" }.to_json)
    Ksef::Auth.cache[[ BASE, SELLER_NIP, "token:#{Digest::SHA256.hexdigest(KSEF_TOKEN)}" ]] =
      Ksef::Auth::Tokens.new(access_token: "stale", access_valid_until: Time.now + 900, refresh_token: "old-refresh", refresh_valid_until: Time.now + 86_400)
    stale = stub_request(:post, "#{BASE}/sessions/online").with(headers: { "Authorization" => "Bearer stale" })
      .to_return(status: 401, body: { title: "Unauthorized", status: 401, detail: "Token expired" }.to_json)

    result = client.send_invoice(@xml)

    assert_equal :accepted, result.status
    assert_requested stale, times: 1
    assert_requested :post, "#{BASE}/auth/challenge", times: 1
  end

  test "the access token is reused across invoices" do
    stub_login
    stub_session
    stub_status(accepted)

    2.times { assert_equal :accepted, client.send_invoice(@xml).status }

    assert_requested :post, "#{BASE}/auth/challenge", times: 1
    assert_requested :post, "#{BASE}/sessions/online", times: 2
  end

  test "an expired access token is refreshed with the refresh token" do
    stub_session(access: "access-refreshed")
    stub_status(accepted)
    refresh = stub_request(:post, "#{BASE}/auth/token/refresh").with(headers: { "Authorization" => "Bearer refresh-jwt" })
      .to_return(status: 200, body: { accessToken: { token: "access-refreshed", validUntil: (Time.now + 900).iso8601 } }.to_json)
    Ksef::Auth.cache[[ BASE, SELLER_NIP, "token:#{Digest::SHA256.hexdigest(KSEF_TOKEN)}" ]] =
      Ksef::Auth::Tokens.new(access_token: "old", access_valid_until: Time.now - 1, refresh_token: "refresh-jwt", refresh_valid_until: Time.now + 86_400)

    assert_equal :accepted, client.send_invoice(@xml).status
    assert_requested refresh
    assert_not_requested :post, "#{BASE}/auth/challenge"
  end

  test "a rotated MF key (21470) refetches the keys and retries once" do
    stub_login
    stub_session
    stub_status(accepted)
    stub_request(:post, "#{BASE}/sessions/online").to_return(
      { status: 400, body: { title: "Bad Request", status: 400, errors: [ { code: 21470, description: "Nieznany klucz" } ] }.to_json }
    ).then.to_return do |request|
      body = JSON.parse(request.body)
      @sent[:key] = oaep_decrypt(Base64.decode64(body.dig("encryption", "encryptedSymmetricKey")))
      @sent[:iv] = Base64.decode64(body.dig("encryption", "initializationVector"))
      { status: 201, body: { referenceNumber: SESSION, validUntil: (Time.now + 43_200).iso8601 }.to_json }
    end

    assert_equal :accepted, client.send_invoice(@xml).status
    assert_requested :get, "#{BASE}/security/public-key-certificates", times: 2
  end

  test "a failed close doesn't lose an invoice KSeF already has" do
    stub_login
    stub_session
    stub_status(accepted)
    stub_request(:post, "#{BASE}/sessions/online/#{SESSION}/close").to_timeout

    assert_equal :accepted, client.send_invoice(@xml).status
  end

  test "invoice_status stays pending while KSeF can't be asked" do
    stub_login
    stub_request(:get, "#{BASE}/sessions/#{SESSION}/invoices/#{INVOICE}").to_timeout

    result = client.invoice_status(SESSION, INVOICE)

    assert_equal :pending, result.status
    assert_equal "#{SESSION}/#{INVOICE}", result.reference_number
    assert_match(/unreachable/, result.error)
  end

  test "certificate login: an XAdES-signed AuthTokenRequest for the NIP and the challenge" do
    key = OpenSSL::PKey::EC.generate("prime256v1")
    certificate = self_signed_certificate(key, subject: "/O=Flosis Test/organizationIdentifier=VATPL-#{SELLER_NIP}/CN=Flosis Test/C=PL")
    stub_login
    stub_session
    stub_status(accepted)
    xades = stub_request(:post, "#{BASE}/auth/xades-signature").with(headers: { "Content-Type" => "application/xml" }) { |request|
      doc = Nokogiri::XML(request.body)
      ns = { "a" => Ksef::Auth::AUTH_TOKEN_REQUEST_NS, "ds" => Ksef::Xades::DS }
      doc.at_xpath("/a:AuthTokenRequest/a:Challenge", ns)&.text == CHALLENGE &&
        doc.at_xpath("/a:AuthTokenRequest/a:ContextIdentifier/a:Nip", ns)&.text == SELLER_NIP &&
        doc.at_xpath("/a:AuthTokenRequest/ds:Signature", ns).present?
    }.to_return(status: 202, body: { referenceNumber: "AUTH-1", authenticationToken: { token: "auth-jwt", validUntil: (Time.now + 600).iso8601 } }.to_json)

    result = client(certificate: certificate, private_key: key).send_invoice(@xml)

    assert_equal :accepted, result.status
    assert_requested xades
    assert_not_requested :post, "#{BASE}/auth/ksef-token"
  end

  test "from_env: nil until configured, a token client, a certificate client" do
    blank = { "KSEF_ENV" => nil, "KSEF_NIP" => nil, "KSEF_TOKEN" => nil, "KSEF_CERT_PATH" => nil, "KSEF_KEY_PATH" => nil, "KSEF_KEY_PASSWORD" => nil }

    with_env(blank) { assert_nil Ksef::Client.from_env }
    with_env(blank.merge("KSEF_TOKEN" => KSEF_TOKEN)) { assert_nil Ksef::Client.from_env }
    with_env(blank.merge("KSEF_NIP" => SELLER_NIP)) { assert_nil Ksef::Client.from_env }

    with_env(blank.merge("KSEF_NIP" => SELLER_NIP, "KSEF_TOKEN" => KSEF_TOKEN, "KSEF_ENV" => "demo")) do
      client = Ksef::Client.from_env
      assert_equal [ :demo, SELLER_NIP ], [ client.environment, client.nip ]
    end

    Dir.mktmpdir do |dir|
      key = OpenSSL::PKey::RSA.generate(2048)
      File.write("#{dir}/c.pem", self_signed_certificate(key).to_pem)
      File.write("#{dir}/k.pem", key.private_to_pem(OpenSSL::Cipher.new("aes-256-cbc"), "pa55"))
      env = blank.merge("KSEF_NIP" => SELLER_NIP, "KSEF_CERT_PATH" => "#{dir}/c.pem", "KSEF_KEY_PATH" => "#{dir}/k.pem")

      with_env(env.merge("KSEF_KEY_PASSWORD" => "pa55")) { assert_kind_of Ksef::Client, Ksef::Client.from_env }
      error = with_env(env.merge("KSEF_KEY_PASSWORD" => "wrong-pa55")) { assert_raises(Ksef::ConfigurationError) { Ksef::Client.from_env } }
      refute_includes error.message, "pa55"
      with_env(env.merge("KSEF_CERT_PATH" => "#{dir}/missing.pem")) { assert_raises(Ksef::ConfigurationError) { Ksef::Client.from_env } }
    end
  end
end
