require "nokogiri"
require "openssl"
require "base64"
require "digest"

module Ksef
  # Signs an XML document (the AuthTokenRequest KSeF asks for at login) with
  # an enveloped XAdES-BES signature, the format KSeF accepts
  # (docs: auth/podpis-xades.md; same shape as the official C# client):
  #   - ds:Reference URI=""  over the whole document: enveloped-signature + exc-c14n, SHA-256
  #   - ds:Reference URI="#SignedProperties" (XAdES type): exc-c14n, SHA-256
  #   - SignedInfo canonicalized with exc-c14n, signed RSA-SHA256 (PKCS#1 v1.5)
  #     or ECDSA-SHA256 (SignatureValue as raw R||S, as XML-DSig 1.1 requires)
  #   - KeyInfo carries the certificate; SignedProperties carry SigningTime and
  #     SigningCertificate (SHA-256 of the certificate + issuer/serial).
  # The output is written without any added whitespace: pretty-printing it
  # afterwards would break the signature.
  module Xades
    DS = "http://www.w3.org/2000/09/xmldsig#"
    XADES = "http://uri.etsi.org/01903/v1.3.2#"
    EXC_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
    ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
    SHA256 = "http://www.w3.org/2001/04/xmlenc#sha256"
    RSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
    ECDSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"
    SIGNED_PROPERTIES_TYPE = "http://uri.etsi.org/01903#SignedProperties"
    SIGNATURE_ID = "Signature"
    SIGNED_PROPERTIES_ID = "SignedProperties"
    C14N = Nokogiri::XML::XML_C14N_EXCLUSIVE_1_0

    module_function

    # `signing_time` is backdated a minute (as the C# client does) so a
    # slightly fast local clock doesn't put it in KSeF's future.
    def sign(xml, certificate:, private_key:, signing_time: Time.now - 60)
      doc = Nokogiri::XML(xml) { |config| config.strict.nonet }
      root = doc.root
      document_digest = digest(doc.canonicalize(C14N))

      # Built in its own document, then copied in place so canonicalization sees it there.
      signature = root.add_child(build_signature(certificate, private_key, signing_time, document_digest))

      signed_properties = signature.at_xpath(".//xades:SignedProperties", "xades" => XADES)
      set_digest(signature, "##{SIGNED_PROPERTIES_ID}", digest(signed_properties.canonicalize(C14N)))

      signed_info = signature.at_xpath("ds:SignedInfo", "ds" => DS)
      value = signature_value(private_key, signed_info.canonicalize(C14N))
      signature.at_xpath("ds:SignatureValue", "ds" => DS).content = Base64.strict_encode64(value)

      doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML, encoding: "UTF-8")
    end

    def digest(bytes) = Base64.strict_encode64(Digest::SHA256.digest(bytes))

    def signature_method(private_key)
      case private_key
      when OpenSSL::PKey::RSA then RSA_SHA256
      when OpenSSL::PKey::EC then ECDSA_SHA256
      else raise ArgumentError, "Unsupported key type #{private_key.class} (use RSA or EC)"
      end
    end

    def signature_value(private_key, data)
      case private_key
      when OpenSSL::PKey::RSA
        private_key.sign(OpenSSL::Digest.new("SHA256"), data)
      when OpenSSL::PKey::EC
        der_to_raw_ecdsa(private_key.sign(OpenSSL::Digest.new("SHA256"), data), private_key)
      end
    end

    # DER SEQUENCE { r, s } -> fixed-width r || s.
    def der_to_raw_ecdsa(der, key)
      size = (key.group.degree + 7) / 8
      r, s = OpenSSL::ASN1.decode(der).value.map { |int| int.value.to_s(2) }
      r.rjust(size, "\0") + s.rjust(size, "\0")
    end

    def build_signature(certificate, private_key, signing_time, document_digest)
      builder = Nokogiri::XML::Builder.new do |x|
        x["ds"].Signature("xmlns:ds" => DS, "Id" => SIGNATURE_ID) do
          x["ds"].SignedInfo do
            x["ds"].CanonicalizationMethod(Algorithm: EXC_C14N)
            x["ds"].SignatureMethod(Algorithm: signature_method(private_key))
            x["ds"].Reference(URI: "") do
              x["ds"].Transforms do
                x["ds"].Transform(Algorithm: ENVELOPED)
                x["ds"].Transform(Algorithm: EXC_C14N)
              end
              x["ds"].DigestMethod(Algorithm: SHA256)
              x["ds"].DigestValue(document_digest)
            end
            x["ds"].Reference(Type: SIGNED_PROPERTIES_TYPE, URI: "##{SIGNED_PROPERTIES_ID}") do
              x["ds"].Transforms do
                x["ds"].Transform(Algorithm: EXC_C14N)
              end
              x["ds"].DigestMethod(Algorithm: SHA256)
              x["ds"].DigestValue("")
            end
          end
          x["ds"].SignatureValue("")
          x["ds"].KeyInfo do
            x["ds"].X509Data do
              x["ds"].X509Certificate(Base64.strict_encode64(certificate.to_der))
            end
          end
          x["ds"].Object do
            x["xades"].QualifyingProperties("xmlns:xades" => XADES, "Target" => "##{SIGNATURE_ID}") do
              x["xades"].SignedProperties("Id" => SIGNED_PROPERTIES_ID) do
                x["xades"].SignedSignatureProperties do
                  x["xades"].SigningTime(signing_time.getutc.iso8601)
                  x["xades"].SigningCertificate do
                    x["xades"].Cert do
                      x["xades"].CertDigest do
                        x["ds"].DigestMethod(Algorithm: SHA256)
                        x["ds"].DigestValue(digest(certificate.to_der))
                      end
                      x["xades"].IssuerSerial do
                        x["ds"].X509IssuerName(certificate.issuer.to_s(OpenSSL::X509::Name::RFC2253))
                        x["ds"].X509SerialNumber(certificate.serial.to_s)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      builder.doc.root
    end

    def set_digest(signature, uri, value)
      reference = signature.at_xpath("ds:SignedInfo/ds:Reference[@URI='#{uri}']", "ds" => DS)
      reference.at_xpath("ds:DigestValue", "ds" => DS).content = value
    end
  end
end
