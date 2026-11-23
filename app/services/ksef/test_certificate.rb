require "openssl"
require "securerandom"
require "fileutils"

module Ksef
  # Makes a self-signed "company seal" certificate that KSeF's TEST
  # environment accepts for XAdES login as the owner of a (fictional) NIP —
  # the same subject the official C# client builds: O=<name>,
  # organizationIdentifier=VATPL-<NIP>, CN=<name>, C=PL. Self-signed
  # certificates work ONLY on TEST; DEMO and production need a qualified
  # seal/signature or a KSeF certificate.
  module TestCertificate
    Files = Data.define(:nip, :certificate_path, :key_path)

    module_function

    # key_type: :rsa (2048-bit) or :ec (P-256).
    def build(nip:, name: "Flosis Test sp. z o.o.", key_type: :rsa, now: Time.now)
      key = key_type.to_sym == :ec ? OpenSSL::PKey::EC.generate("prime256v1") : OpenSSL::PKey::RSA.generate(2048)
      subject = OpenSSL::X509::Name.new([
        [ "O", name, OpenSSL::ASN1::UTF8STRING ],
        [ "organizationIdentifier", "VATPL-#{nip}", OpenSSL::ASN1::UTF8STRING ],
        [ "CN", name, OpenSSL::ASN1::UTF8STRING ],
        [ "C", "PL", OpenSSL::ASN1::PRINTABLESTRING ]
      ])

      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = OpenSSL::BN.new(SecureRandom.hex(16), 16)
      certificate.subject = subject
      certificate.issuer = subject
      certificate.public_key = key.is_a?(OpenSSL::PKey::EC) ? key : key.public_key
      certificate.not_before = now - 3660
      certificate.not_after = now + 2 * 365 * 86_400
      certificate.sign(key, OpenSSL::Digest.new("SHA256"))

      [ certificate, key ]
    end

    # Writes <dir>/<nip>.crt and <dir>/<nip>.key (mode 600).
    def write(nip:, dir:, key_type: :rsa)
      certificate, key = build(nip: nip, key_type: key_type)
      FileUtils.mkdir_p(dir)
      certificate_path = File.join(dir, "#{nip}.crt")
      key_path = File.join(dir, "#{nip}.key")
      File.write(certificate_path, certificate.to_pem)
      File.open(key_path, "w", 0o600) { |f| f.write(key.private_to_pem) }
      File.chmod(0o600, key_path)
      Files.new(nip: nip, certificate_path: certificate_path, key_path: key_path)
    end
  end
end
