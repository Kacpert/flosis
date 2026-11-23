require "test_helper"
require_relative "ksef_test_support"

class Ksef::XadesTest < ActiveSupport::TestCase
  include KsefTestSupport

  NS = { "ds" => Ksef::Xades::DS, "xades" => Ksef::Xades::XADES, "a" => Ksef::Auth::AUTH_TOKEN_REQUEST_NS }.freeze
  CHALLENGE = "20250604-CR-461EA5B000-537A6BA15D-D7"
  SIGNING_TIME = Time.utc(2026, 11, 23, 12, 0, 0)

  def request_xml = Ksef::Auth.auth_token_request(challenge: CHALLENGE, nip: SELLER_NIP)

  def sign_with(key)
    certificate = self_signed_certificate(key, subject: "/O=Flosis Test/organizationIdentifier=VATPL-#{SELLER_NIP}/CN=Flosis Test/C=PL")
    [ Ksef::Xades.sign(request_xml, certificate: certificate, private_key: key, signing_time: SIGNING_TIME), certificate ]
  end

  def c14n(node) = node.canonicalize(Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0)
  def sha256(bytes) = Base64.strict_encode64(Digest::SHA256.digest(bytes))

  def assert_valid_signature(signed, certificate, key)
    doc = Nokogiri::XML(signed)
    signature = doc.root.element_children.last
    assert_equal [ Ksef::Xades::DS, "Signature" ], [ signature.namespace.href, signature.name ]

    # Reference 1: the whole document without the signature (enveloped), exc-c14n, SHA-256.
    root_ref = signature.at_xpath("ds:SignedInfo/ds:Reference[@URI='']", NS)
    assert_equal [ Ksef::Xades::ENVELOPED, Ksef::Xades::EXC_C14N ], root_ref.xpath("ds:Transforms/ds:Transform/@Algorithm", NS).map(&:value)
    assert_equal Ksef::Xades::SHA256, root_ref.at_xpath("ds:DigestMethod/@Algorithm", NS).value
    unsigned = Nokogiri::XML(signed)
    unsigned.at_xpath("//ds:Signature", NS).remove
    assert_equal sha256(c14n(unsigned)), root_ref.at_xpath("ds:DigestValue", NS).text

    # Reference 2: the XAdES SignedProperties.
    props_ref = signature.at_xpath("ds:SignedInfo/ds:Reference[@URI='#SignedProperties']", NS)
    assert_equal "http://uri.etsi.org/01903#SignedProperties", props_ref["Type"]
    signed_properties = doc.at_xpath("//xades:SignedProperties[@Id='SignedProperties']", NS)
    assert_equal sha256(c14n(signed_properties)), props_ref.at_xpath("ds:DigestValue", NS).text

    assert_equal Ksef::Xades::EXC_C14N, signature.at_xpath("ds:SignedInfo/ds:CanonicalizationMethod/@Algorithm", NS).value
    assert_equal certificate.to_der, Base64.decode64(signature.at_xpath("ds:KeyInfo/ds:X509Data/ds:X509Certificate", NS).text)

    value = Base64.decode64(signature.at_xpath("ds:SignatureValue", NS).text)
    signed_info = c14n(signature.at_xpath("ds:SignedInfo", NS))
    if key.is_a?(OpenSSL::PKey::EC)
      assert_equal 64, value.bytesize, "ECDSA P-256 SignatureValue must be raw r||s"
      r, s = value.unpack("a32a32").map { |half| OpenSSL::BN.new(half, 2) }
      value = OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s) ]).to_der
    end
    assert certificate.public_key.verify(OpenSSL::Digest.new("SHA256"), value, signed_info), "SignatureValue does not verify"
    doc
  end

  test "RSA: enveloped XAdES-BES that verifies with the certificate" do
    key = OpenSSL::PKey::RSA.generate(2048)
    signed, certificate = sign_with(key)
    doc = assert_valid_signature(signed, certificate, key)

    assert_equal Ksef::Xades::RSA_SHA256, doc.at_xpath("//ds:SignatureMethod/@Algorithm", NS).value
  end

  test "ECDSA P-256: SignatureValue is r||s and verifies" do
    key = OpenSSL::PKey::EC.generate("prime256v1")
    signed, certificate = sign_with(key)
    doc = assert_valid_signature(signed, certificate, key)

    assert_equal Ksef::Xades::ECDSA_SHA256, doc.at_xpath("//ds:SignatureMethod/@Algorithm", NS).value
  end

  test "SignedProperties: signing time and the signing certificate's digest, issuer and serial" do
    key = OpenSSL::PKey::RSA.generate(2048)
    signed, certificate = sign_with(key)
    doc = Nokogiri::XML(signed)

    assert_equal "#Signature", doc.at_xpath("//xades:QualifyingProperties/@Target", NS).value
    assert_equal "Signature", doc.at_xpath("//ds:Signature/@Id", NS).value
    assert_equal "2026-11-23T12:00:00Z", doc.at_xpath("//xades:SigningTime", NS).text
    assert_equal sha256(certificate.to_der), doc.at_xpath("//xades:CertDigest/ds:DigestValue", NS).text
    assert_equal Ksef::Xades::SHA256, doc.at_xpath("//xades:CertDigest/ds:DigestMethod/@Algorithm", NS).value
    assert_equal "4242", doc.at_xpath("//xades:IssuerSerial/ds:X509SerialNumber", NS).text
    assert_includes doc.at_xpath("//xades:IssuerSerial/ds:X509IssuerName", NS).text, "VATPL-#{SELLER_NIP}"
  end

  test "the signed request still carries the challenge and context, and changing them breaks the digest" do
    key = OpenSSL::PKey::RSA.generate(2048)
    signed, = sign_with(key)
    doc = Nokogiri::XML(signed)

    assert_equal CHALLENGE, doc.at_xpath("/a:AuthTokenRequest/a:Challenge", NS).text
    assert_equal SELLER_NIP, doc.at_xpath("/a:AuthTokenRequest/a:ContextIdentifier/a:Nip", NS).text
    assert_equal "certificateSubject", doc.at_xpath("/a:AuthTokenRequest/a:SubjectIdentifierType", NS).text

    doc.at_xpath("//a:Nip", NS).content = "7980332920"
    digest = doc.at_xpath("//ds:Reference[@URI='']/ds:DigestValue", NS).text
    doc.at_xpath("//ds:Signature", NS).remove
    refute_equal digest, sha256(c14n(doc))
  end

  test "no whitespace is added inside the signature" do
    signed, = sign_with(OpenSSL::PKey::RSA.generate(2048))
    signature = Nokogiri::XML(signed).at_xpath("//ds:Signature", NS)

    assert signature.xpath(".//text()").none? { |text| text.content.strip.empty? }
  end

  test "the unsigned AuthTokenRequest matches KSeF's auth schema" do
    assert_empty schema_errors(request_xml, "schemat_auth_v2-1.xsd")
  end
end
