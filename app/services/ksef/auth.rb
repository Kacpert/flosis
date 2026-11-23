require "nokogiri"
require "digest"

module Ksef
  # Logs in to KSeF for one seller NIP and hands out a valid access token
  # (docs: uwierzytelnianie.md). The flow:
  #   1. POST /auth/challenge
  #   2. either POST /auth/ksef-token  — "<KSeF token>|<challenge ms>" RSA-OAEP encrypted with the MF key
  #      or     POST /auth/xades-signature — an AuthTokenRequest XAdES-signed with our certificate
  #   3. poll GET /auth/{reference} until KSeF has checked it (code 100 → 200)
  #   4. POST /auth/token/redeem → access token (minutes) + refresh token (days)
  # Tokens are cached in memory per process (keyed by environment, NIP and a
  # hash of the credential); a spent access token is renewed with the refresh
  # token before falling back to a full login.
  class Auth
    AUTH_TOKEN_REQUEST_NS = "http://ksef.mf.gov.pl/auth/token/2.1"
    IN_PROGRESS = 100
    SUCCESS = 200
    EXPIRY_MARGIN = 60

    Tokens = Data.define(:access_token, :access_valid_until, :refresh_token, :refresh_valid_until)

    @cache = {}
    @lock = Mutex.new

    class << self
      attr_reader :cache, :lock

      def reset!
        @lock.synchronize { @cache.clear }
      end
    end

    def initialize(http:, nip:, ksef_token: nil, certificate: nil, private_key: nil,
                   poll_timeout: 30, sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now })
      raise ArgumentError, "KSeF login needs a KSeF token or a certificate with its key" unless ksef_token || (certificate && private_key)

      @http = http
      @nip = nip
      @ksef_token = ksef_token
      @certificate = certificate
      @private_key = private_key
      @poll_timeout = poll_timeout
      @sleeper = sleeper
      @clock = clock
    end

    def access_token
      self.class.lock.synchronize do
        tokens = self.class.cache[cache_key]
        return tokens.access_token if tokens && fresh?(tokens.access_valid_until)

        tokens = (refresh(tokens) if tokens && fresh?(tokens.refresh_valid_until)) || login
        self.class.cache[cache_key] = tokens
        tokens.access_token
      end
    end

    # After KSeF answers 401: forget the access token (the refresh token may still work).
    def invalidate!
      self.class.lock.synchronize do
        tokens = self.class.cache[cache_key]
        self.class.cache[cache_key] = tokens.with(access_valid_until: Time.at(0)) if tokens
      end
    end

    # The unsigned AuthTokenRequest (schema auth/token 2.1, on every environment since 2026-05-11).
    def self.auth_token_request(challenge:, nip:)
      Nokogiri::XML::Builder.new(encoding: "utf-8") do |x|
        x.AuthTokenRequest(xmlns: AUTH_TOKEN_REQUEST_NS) do
          x.Challenge(challenge)
          x.ContextIdentifier { x.Nip(nip) }
          x.SubjectIdentifierType("certificateSubject")
        end
      end.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    private

    def now = @clock.call

    def fresh?(valid_until)
      valid_until && valid_until > now + EXPIRY_MARGIN
    end

    def cache_key
      credential = @ksef_token ? "token:#{Digest::SHA256.hexdigest(@ksef_token)}" : "cert:#{Digest::SHA256.hexdigest(@certificate.to_der)}"
      [ @http.base_url, @nip, credential ]
    end

    def login
      challenge = @http.post_json("/auth/challenge")
      started = @ksef_token ? start_with_token(challenge) : start_with_certificate(challenge)
      authentication_token = started.dig("authenticationToken", "token")
      wait_until_verified(started["referenceNumber"], authentication_token)
      tokens_from(@http.post_json("/auth/token/redeem", nil, token: authentication_token))
    end

    def start_with_token(challenge)
      key = PublicKeys.new(@http).for(:token)
      encrypted = Crypto.encrypt_ksef_token(key.public_key, @ksef_token, challenge.fetch("timestampMs"))
      @http.post_json("/auth/ksef-token", {
        challenge: challenge.fetch("challenge"),
        contextIdentifier: { type: "Nip", value: @nip },
        encryptedToken: Crypto.base64(encrypted),
        publicKeyId: key.public_key_id
      })
    end

    def start_with_certificate(challenge)
      request = self.class.auth_token_request(challenge: challenge.fetch("challenge"), nip: @nip)
      signed = Xades.sign(request, certificate: @certificate, private_key: @private_key)
      @http.post_xml("/auth/xades-signature", signed)
    end

    def wait_until_verified(reference, authentication_token)
      deadline = now + @poll_timeout
      delay = 0.5
      loop do
        status = @http.get("/auth/#{reference}", token: authentication_token)&.fetch("status", nil) || {}
        code = status["code"].to_i
        return if code == SUCCESS
        raise AuthError, refusal(status) unless code == IN_PROGRESS
        raise AuthError, "KSeF login still being verified after #{@poll_timeout}s" if now >= deadline

        @sleeper.call(delay)
        delay = [ delay * 2, 3 ].min
      end
    end

    def refusal(status)
      details = Array(status["details"]).first(2).join("; ").presence
      "KSeF refused the login: #{[ status['description'], details ].compact.join(': ').truncate(300)} (code #{status['code']})"
    end

    def refresh(tokens)
      body = @http.post_json("/auth/token/refresh", nil, token: tokens.refresh_token)
      tokens.with(access_token: body.dig("accessToken", "token"), access_valid_until: time(body.dig("accessToken", "validUntil")))
    rescue ApiError, TransportError => e
      Rails.logger.warn("[Ksef::Auth] token refresh failed, logging in again: #{e.message}")
      nil
    end

    def tokens_from(body)
      Tokens.new(
        access_token: body.dig("accessToken", "token"),
        access_valid_until: time(body.dig("accessToken", "validUntil")),
        refresh_token: body.dig("refreshToken", "token"),
        refresh_valid_until: time(body.dig("refreshToken", "validUntil"))
      )
    end

    def time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      now + 300
    end
  end
end
