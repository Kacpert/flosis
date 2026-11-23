require "test_helper"
require_relative "ksef_test_support"

class Ksef::CryptoTest < ActiveSupport::TestCase
  include KsefTestSupport

  test "invoices: AES-256-CBC with PKCS#7 padding" do
    key = Ksef::Crypto.symmetric_key
    iv = Ksef::Crypto.initialization_vector
    plain = "<Faktura>Kraków</Faktura>" * 3

    encrypted = Ksef::Crypto.aes_encrypt(plain, key, iv)

    assert_equal [ 32, 16 ], [ key.bytesize, iv.bytesize ]
    assert_equal 0, encrypted.bytesize % 16
    decipher = OpenSSL::Cipher.new("aes-256-cbc").tap(&:decrypt)
    decipher.key = key
    decipher.iv = iv
    assert_equal plain.b, decipher.update(encrypted) + decipher.final
    # A block-aligned input still gets a full padding block.
    assert_equal 32, Ksef::Crypto.aes_encrypt("x" * 16, key, iv).bytesize
  end

  test "keys: RSA-OAEP with SHA-256 and MGF1-SHA-256" do
    secret = SecureRandom.random_bytes(32)
    encrypted = Ksef::Crypto.rsa_oaep_encrypt(mf_certificate.public_key, secret)

    assert_equal secret, oaep_decrypt(encrypted)
    # Not the OAEP-SHA-1 default.
    assert_raises(OpenSSL::PKey::PKeyError) { mf_key.decrypt(encrypted, "rsa_padding_mode" => "oaep") }
  end

  test "KSeF token login secret is '<token>|<challenge timestamp ms>'" do
    encrypted = Ksef::Crypto.encrypt_ksef_token(mf_certificate.public_key, "20261123-EC-1|nip-1953016471|abc", 1_795_472_195_999)

    assert_equal "20261123-EC-1|nip-1953016471|abc|1795472195999", oaep_decrypt(encrypted)
  end

  test "SHA-256 in Base64" do
    assert_equal "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=", Ksef::Crypto.sha256_base64("abc")
  end
end
