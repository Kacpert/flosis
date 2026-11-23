require "openssl"

module Ksef
  # Sends one FA(3) invoice to KSeF and reports what KSeF made of it
  # (docs: sesja-interaktywna.md). send_invoice opens an online session with a
  # fresh AES key, sends the encrypted XML, closes the session and waits a
  # little for KSeF's verdict; invoice_status asks again later for one that
  # was still :pending. Nothing raises: every outcome is a Ksef::SendResult.
  #
  # Configured from ENV by Client.from_env:
  #   KSEF_ENV         test | demo | production (default test)
  #   KSEF_NIP         the seller NIP we log in for
  #   KSEF_TOKEN       a KSeF token, or
  #   KSEF_CERT_PATH + KSEF_KEY_PATH (+ KSEF_KEY_PASSWORD) — a certificate
  #                    (PEM or DER) and its RSA/EC private key, for XAdES login
  class Client
    FORM_CODE = { systemCode: "FA (3)", schemaVersion: "1-0E", value: "FA" }.freeze
    STATUS_TIMEOUT = 15

    # KSeF invoice status codes (GET /sessions/{ref}/invoices/{ref}).
    PROCESSING = [ 100, 150 ].freeze
    ACCEPTED = 200
    DUPLICATE = 440
    KSEF_GAVE_UP = [ 405, 500, 550 ].freeze # session error / unknown / cancelled by KSeF — send again
    UNKNOWN_PUBLIC_KEY = 21470

    attr_reader :environment, :nip

    # nil when KSEF_NIP or the credentials are missing; raises
    # Ksef::ConfigurationError when they are set but unusable.
    def self.from_env(env = ENV)
      nip = env["KSEF_NIP"].to_s.strip.presence
      token = env["KSEF_TOKEN"].to_s.strip.presence
      cert_path = env["KSEF_CERT_PATH"].to_s.strip.presence
      key_path = env["KSEF_KEY_PATH"].to_s.strip.presence
      return nil unless nip && (token || (cert_path && key_path))

      credentials =
        if token
          { ksef_token: token }
        else
          { certificate: read_certificate(cert_path), private_key: read_key(key_path, env["KSEF_KEY_PASSWORD"].presence) }
        end
      new(environment: Ksef.environment, nip: nip, **credentials)
    end

    def self.read_certificate(path)
      OpenSSL::X509::Certificate.new(File.binread(path))
    rescue SystemCallError, OpenSSL::X509::CertificateError => e
      raise ConfigurationError, "KSEF_CERT_PATH is not a readable certificate (#{e.class.name.demodulize})"
    end

    def self.read_key(path, password)
      OpenSSL::PKey.read(File.binread(path), password.to_s)
    rescue SystemCallError, OpenSSL::PKey::PKeyError, ArgumentError => e
      raise ConfigurationError, "KSEF_KEY_PATH is not a readable private key, or KSEF_KEY_PASSWORD is wrong (#{e.class.name.demodulize})"
    end

    def initialize(environment:, nip:, ksef_token: nil, certificate: nil, private_key: nil,
                   http: nil, status_timeout: STATUS_TIMEOUT, sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now })
      @environment = environment
      @nip = nip
      @http = http || Http.new(Ksef.api_url(environment))
      @status_timeout = status_timeout
      @sleeper = sleeper
      @clock = clock
      @auth = Auth.new(http: @http, nip: nip, ksef_token: ksef_token, certificate: certificate,
                       private_key: private_key, sleeper: sleeper, clock: clock)
    end

    def send_invoice(xml)
      sent = submit(xml.to_s.b)
      reference = "#{sent[:session]}/#{sent[:invoice]}"
      log("invoice sent (#{reference})")
      close_session(sent[:session])
      wait_for_verdict(sent[:session], sent[:invoice])
    rescue Error, KeyError => e
      log("send failed: #{e.message}", :warn)
      SendResult.new(status: :failed, error: e.message)
    end

    # KSeF's current verdict on an invoice sent earlier. When KSeF can't be
    # asked right now (network, login, an error answer) the result stays
    # :pending with the reason in `error`: the invoice is already with KSeF.
    def invoice_status(session_reference, invoice_reference)
      reference = "#{session_reference}/#{invoice_reference}"
      result_from(fetch_status(session_reference, invoice_reference), reference)
    rescue Error => e
      SendResult.new(status: :pending, reference_number: reference, error: e.message)
    end

    private

    def submit(bytes, retried: false)
      authorized do |token|
        key = Crypto.symmetric_key
        iv = Crypto.initialization_vector
        mf_key = PublicKeys.new(@http).for(:symmetric)
        session = @http.post_json("/sessions/online", {
          formCode: FORM_CODE,
          encryption: {
            encryptedSymmetricKey: Crypto.base64(Crypto.rsa_oaep_encrypt(mf_key.public_key, key)),
            initializationVector: Crypto.base64(iv),
            publicKeyId: mf_key.public_key_id
          }
        }, token: token)
        session_reference = session.fetch("referenceNumber")

        encrypted = Crypto.aes_encrypt(bytes, key, iv)
        invoice = @http.post_json("/sessions/online/#{session_reference}/invoices", {
          invoiceHash: Crypto.sha256_base64(bytes),
          invoiceSize: bytes.bytesize,
          encryptedInvoiceHash: Crypto.sha256_base64(encrypted),
          encryptedInvoiceSize: encrypted.bytesize,
          encryptedInvoiceContent: Crypto.base64(encrypted)
        }, token: token)
        { session: session_reference, invoice: invoice.fetch("referenceNumber") }
      end
    rescue ApiError => e
      raise unless e.code == UNKNOWN_PUBLIC_KEY && !retried

      PublicKeys.reset! # KSeF rotated its key: fetch the new one and try once more
      submit(bytes, retried: true)
    end

    # Runs the block with an access token; on a 401 logs in afresh once.
    def authorized
      yield @auth.access_token
    rescue ApiError => e
      raise unless e.http_status == 401

      @auth.invalidate!
      yield @auth.access_token
    end

    # Closing only starts the session's collective UPO; a failure here doesn't
    # touch the invoice (KSeF closes the session itself after 12h).
    def close_session(session_reference)
      authorized { |token| @http.post_json("/sessions/online/#{session_reference}/close", nil, token: token) }
    rescue Error => e
      log("closing session #{session_reference} failed: #{e.message}", :warn)
    end

    def wait_for_verdict(session_reference, invoice_reference)
      deadline = @clock.call + @status_timeout
      delay = 0.5
      loop do
        result = invoice_status(session_reference, invoice_reference)
        return result unless result.pending?
        return result if @clock.call >= deadline

        @sleeper.call(delay)
        delay = [ delay * 2, 3 ].min
      end
    end

    def fetch_status(session_reference, invoice_reference)
      authorized { |token| @http.get("/sessions/#{session_reference}/invoices/#{invoice_reference}", token: token) }
    end

    def result_from(body, reference)
      status = body&.fetch("status", nil) || {}
      code = status["code"].to_i

      if code == ACCEPTED && body["ksefNumber"].present?
        SendResult.new(status: :accepted, ksef_number: body["ksefNumber"], reference_number: reference)
      elsif code == DUPLICATE && (original = status.dig("extensions", "originalKsefNumber")).present?
        # Already in KSeF (an earlier send got through): that one is ours.
        SendResult.new(status: :accepted, ksef_number: original, reference_number: reference,
                       error: "Duplicate of an invoice already in KSeF (code 440)")
      elsif PROCESSING.include?(code) || code == ACCEPTED
        SendResult.new(status: :pending, reference_number: reference)
      elsif KSEF_GAVE_UP.include?(code)
        SendResult.new(status: :failed, reference_number: reference, error: "KSeF did not process the invoice: #{describe(status)}")
      else
        SendResult.new(status: :rejected, reference_number: reference, error: "Rejected by KSeF: #{describe(status)}")
      end
    end

    def describe(status)
      details = Array(status["details"]).first(3).join("; ").presence
      "#{[ status['description'].presence || 'no description', details ].compact.join(': ').truncate(400)} (code #{status['code']})"
    end

    def log(message, level = :info)
      Rails.logger.public_send(level, "[Ksef::Client #{@environment} #{@nip}] #{message}")
    end
  end
end
