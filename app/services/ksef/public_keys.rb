require "openssl"
require "base64"

module Ksef
  # The Ministry of Finance's public keys, from GET /security/public-key-certificates.
  # KSeF publishes one certificate per use — KsefTokenEncryption (logging in
  # with a KSeF token) and SymmetricKeyEncryption (the per-session invoice
  # key) — and rotates them now and then, so the list is cached per process
  # for a few hours and dropped when KSeF says a key id is unknown (21470).
  class PublicKeys
    Key = Data.define(:public_key, :public_key_id)

    TTL = 6 * 3600
    USAGES = { token: "KsefTokenEncryption", symmetric: "SymmetricKeyEncryption" }.freeze

    @cache = {}
    @lock = Mutex.new

    class << self
      def reset!
        @lock.synchronize { @cache.clear }
      end

      def fetch(http, now: Time.now)
        @lock.synchronize do
          entry = @cache[http.base_url]
          return entry[:list] if entry && entry[:at] > now - TTL

          list = Array(http.get("/security/public-key-certificates"))
          @cache[http.base_url] = { list: list, at: now }
          list
        end
      end
    end

    def initialize(http)
      @http = http
    end

    # Picks the certificate for `usage` (:token or :symmetric) valid now,
    # preferring the newest one, as the KSeF docs ask.
    def for(usage, now: Time.now)
      name = USAGES.fetch(usage)
      entry = self.class.fetch(@http, now: now)
        .select { |c| Array(c["usage"]).include?(name) && valid_at?(c, now) }
        .max_by { |c| Time.iso8601(c["validFrom"]) }
      raise Error, "KSeF published no #{name} key" unless entry

      certificate = OpenSSL::X509::Certificate.new(Base64.decode64(entry["certificate"]))
      Key.new(public_key: certificate.public_key, public_key_id: entry["publicKeyId"])
    end

    private

    def valid_at?(entry, now)
      Time.iso8601(entry["validFrom"]) <= now && now <= Time.iso8601(entry["validTo"])
    rescue ArgumentError, TypeError
      false
    end
  end
end
