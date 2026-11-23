require "openssl"
require "base64"
require "digest"
require "securerandom"

module Ksef
  # The encryption KSeF asks for, in one place:
  #   - an invoice travels AES-256-CBC (PKCS#7) encrypted with a fresh key/IV per session;
  #   - that key, and a KSeF token at login, travel RSA-OAEP encrypted
  #     (SHA-256, MGF1-SHA-256) with the Ministry of Finance's public key;
  #   - hashes are SHA-256, Base64.
  module Crypto
    OAEP_SHA256 = {
      "rsa_padding_mode" => "oaep",
      "rsa_oaep_md" => "sha256",
      "rsa_mgf1_md" => "sha256"
    }.freeze

    def self.symmetric_key = SecureRandom.random_bytes(32)
    def self.initialization_vector = SecureRandom.random_bytes(16)

    def self.aes_encrypt(data, key, iv)
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      cipher.update(data.to_s.b) + cipher.final
    end

    # `public_key` is an OpenSSL::PKey (e.g. certificate.public_key).
    def self.rsa_oaep_encrypt(public_key, data)
      public_key.encrypt(data.to_s.b, OAEP_SHA256)
    end

    # The login secret for /auth/ksef-token: "<token>|<challenge timestamp in ms>".
    def self.encrypt_ksef_token(public_key, token, timestamp_ms)
      rsa_oaep_encrypt(public_key, "#{token}|#{timestamp_ms}")
    end

    def self.sha256_base64(data)
      Base64.strict_encode64(Digest::SHA256.digest(data.to_s.b))
    end

    def self.base64(data) = Base64.strict_encode64(data.to_s.b)
  end
end
