require "digest"
require "base64"

module Ksef
  # Builds the KOD I link printed as a QR code on an invoice sent online: it
  # lets anyone check on the government's site that this exact invoice is in
  # KSeF. Format (KSeF docs, "Kody weryfikujące QR"):
  #   <qr host>/invoice/<seller NIP>/<issue date DD-MM-YYYY>/<SHA-256 of the XML, Base64URL, no padding>
  # The hash is of the exact bytes sent to KSeF — rebuild the XML and the
  # link stops matching.
  module Qr
    def self.invoice_url(seller_nip:, issued_on:, xml:, environment: Ksef.environment)
      host = Ksef::ENVIRONMENTS.fetch(environment).fetch(:qr)
      "#{host}/invoice/#{seller_nip}/#{issued_on.strftime('%d-%m-%Y')}/#{xml_hash(xml)}"
    end

    def self.xml_hash(xml)
      Base64.urlsafe_encode64(Digest::SHA256.digest(xml.to_s.b), padding: false)
    end
  end
end
