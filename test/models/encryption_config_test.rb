require "test_helper"

class EncryptionConfigTest < ActiveSupport::TestCase
  test "ActiveRecord encryption is configured with keys" do
    config = ActiveRecord::Encryption.config
    assert config.primary_key.present?, "primary_key must be set"
    assert config.deterministic_key.present?, "deterministic_key must be set"
    assert config.key_derivation_salt.present?, "key_derivation_salt must be set"
  end

  test "a string can be encrypted and decrypted round-trip" do
    encryptor = ActiveRecord::Encryption::Encryptor.new
    cipher = encryptor.encrypt("secret-token", key_provider: ActiveRecord::Encryption.key_provider)
    assert_not_equal "secret-token", cipher
    assert_equal "secret-token", encryptor.decrypt(cipher, key_provider: ActiveRecord::Encryption.key_provider)
  end
end
