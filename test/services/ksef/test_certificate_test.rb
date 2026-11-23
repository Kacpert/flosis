require "test_helper"

class Ksef::TestCertificateTest < ActiveSupport::TestCase
  test "a self-signed company seal for the NIP, as KSeF TEST expects" do
    certificate, key = Ksef::TestCertificate.build(nip: "5265877635")
    subject = certificate.subject.to_a.to_h { |name, value, _type| [ name, value ] }

    assert_equal "VATPL-5265877635", subject["organizationIdentifier"]
    assert_equal "PL", subject["C"]
    assert subject["O"].present?
    assert subject["CN"].present?
    refute subject.key?("GN") || subject.key?("SN"), "a seal must not name a person"
    assert_equal certificate.subject.to_der, certificate.issuer.to_der
    assert certificate.verify(certificate.public_key)
    assert_kind_of OpenSSL::PKey::RSA, key
    assert_equal 2048, key.n.num_bits
    assert certificate.not_before < Time.now
    assert certificate.not_after > Time.now + 365 * 86_400
  end

  test "an EC P-256 key on request" do
    certificate, key = Ksef::TestCertificate.build(nip: "5265877635", key_type: :ec)

    assert_kind_of OpenSSL::PKey::EC, key
    assert_equal "prime256v1", key.group.curve_name
    assert certificate.verify(key)
  end

  test "writes the certificate and a private key only its owner can read" do
    Dir.mktmpdir do |dir|
      files = Ksef::TestCertificate.write(nip: "5265877635", dir: dir)

      certificate = OpenSSL::X509::Certificate.new(File.read(files.certificate_path))
      key = OpenSSL::PKey.read(File.read(files.key_path))
      assert certificate.check_private_key(key)
      assert_equal 0o600, File.stat(files.key_path).mode & 0o777
    end
  end
end
