# Shared builders for the Ksef tests: a sample invoice per VAT treatment,
# the vendored FA(3) schema (validated offline: its imports point at the
# local copies in test/fixtures/files/ksef/), and throwaway certificates.
module KsefTestSupport
  FIXTURES = Rails.root.join("test/fixtures/files/ksef")
  FA3_NS = { "fa" => Ksef::Fa3::NAMESPACE }.freeze
  SELLER_NIP = "5265877635"
  BUYER_NIP = "7980332920"

  def self.schema(file)
    @schemas ||= {}
    @schemas[file] ||= begin
      path = FIXTURES.join(file).to_s
      Nokogiri::XML::Schema.from_document(Nokogiri::XML(File.read(path), path))
    end
  end

  def schema_errors(xml, file = "schemat_FA3_v1-0E.xsd")
    KsefTestSupport.schema(file).validate(Nokogiri::XML(xml)).map(&:message)
  end

  def seller
    Ksef::Party.new(name: "Flosis sp. z o.o.", nip: SELLER_NIP, country_code: "PL",
                    address_line1: "ul. Prosta 1", address_line2: "00-001 Warszawa")
  end

  def buyer_for(treatment)
    case treatment
    when :pl_23
      Ksef::Party.new(name: "Klient sp. z o.o.", nip: BUYER_NIP, country_code: "PL",
                      address_line1: "ul. Polna 2", address_line2: "30-001 Kraków")
    when :eu_reverse_charge
      Ksef::Party.new(name: "Kunde GmbH", eu_vat_number: "DE123456789", country_code: "DE",
                      address_line1: "Hauptstraße 1", address_line2: "10115 Berlin")
    else
      Ksef::Party.new(name: "Customer Inc.", tax_id: nil, country_code: "US", address_line1: "1 Main St, Springfield, IL")
    end
  end

  def sample_invoice(treatment = :pl_23, **overrides)
    pl = treatment == :pl_23
    attributes = {
      number: "FV/2026/11/0004",
      issued_on: Date.new(2026, 11, 23),
      sold_on: Date.new(2026, 11, 23),
      currency: "USD",
      seller: seller,
      buyer: buyer_for(treatment),
      vat_treatment: treatment,
      lines: [
        Ksef::Line.new(name: "Flosis Team plan, November 2026", net: BigDecimal("80.00"), vat_rate: (23 if pl),
                       vat: pl ? BigDecimal("18.40") : BigDecimal("0"), gross: pl ? BigDecimal("98.40") : BigDecimal("80.00")),
        Ksef::Line.new(name: "AI usage", net: BigDecimal("20.10"), vat_rate: (23 if pl),
                       vat: pl ? BigDecimal("4.62") : BigDecimal("0"), gross: pl ? BigDecimal("24.72") : BigDecimal("20.10"))
      ],
      net: BigDecimal("100.10"),
      vat: pl ? BigDecimal("23.02") : BigDecimal("0"),
      gross: pl ? BigDecimal("123.12") : BigDecimal("100.10"),
      exchange_rate: (BigDecimal("4.0123") if pl),
      exchange_rate_date: (Date.new(2026, 11, 20) if pl),
      vat_pln: (BigDecimal("92.36") if pl),
      paid_on: Date.new(2026, 11, 23)
    }
    Ksef::Invoice.new(**attributes.merge(overrides))
  end

  def self_signed_certificate(key, subject: "/O=Test sp. z o.o./CN=Test/C=PL")
    name = OpenSSL::X509::Name.parse(subject)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 4242
    certificate.subject = name
    certificate.issuer = name
    certificate.public_key = key.is_a?(OpenSSL::PKey::EC) ? key : key.public_key
    certificate.not_before = Time.now - 3600
    certificate.not_after = Time.now + 86_400
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    certificate
  end

  # The Ministry's key pair stand-in: tests encrypt to its certificate and
  # decrypt with its private key to see what was really sent.
  def mf_key
    @mf_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def mf_certificate
    @mf_certificate ||= self_signed_certificate(mf_key, subject: "/CN=Ministerstwo Finansow/C=PL")
  end

  def oaep_decrypt(data)
    mf_key.decrypt(data, Ksef::Crypto::OAEP_SHA256)
  end
end
