# KSeF (Polish national e-invoicing) helpers for the TEST environment.
#
#   bin/rails "ksef:test_certificate[1234567890]"   # self-signed seal for a fictional NIP (random when omitted)
#   KSEF_ENV=test KSEF_NIP=… KSEF_CERT_PATH=… KSEF_KEY_PATH=… bin/rails ksef:smoke
#   bin/rails "ksef:smoke[all]"                       # one invoice per VAT treatment
namespace :ksef do
  desc "Generate a self-signed certificate KSeF TEST accepts for a NIP, into tmp/ksef/ (KEY_TYPE=ec for P-256)"
  task :test_certificate, [ :nip ] => :environment do |_task, args|
    nip = args[:nip].to_s.delete("^0-9").presence || Ksef::Nip.random
    abort "#{nip} is not a valid NIP (checksum)" unless Ksef::Nip.valid?(nip)

    files = Ksef::TestCertificate.write(nip: nip, dir: Rails.root.join("tmp/ksef").to_s, key_type: ENV.fetch("KEY_TYPE", "rsa"))
    puts "Self-signed KSeF TEST certificate for NIP #{nip} (accepted on TEST only; use fictional NIPs there)."
    puts
    puts "KSEF_ENV=test"
    puts "KSEF_NIP=#{nip}"
    puts "KSEF_CERT_PATH=#{files.certificate_path}"
    puts "KSEF_KEY_PATH=#{files.key_path}"
  end

  desc "Send a fictional sample invoice to the configured KSeF environment (not production) and print the result"
  task :smoke, [ :treatment ] => :environment do |_task, args|
    abort "ksef:smoke refuses to run against production" if Ksef.environment == :production

    client = Ksef::Client.from_env
    abort "KSeF is not configured: set KSEF_NIP and KSEF_TOKEN, or KSEF_CERT_PATH + KSEF_KEY_PATH" unless client

    treatments = args[:treatment] == "all" ? Ksef::Fa3::TREATMENTS : [ (args[:treatment].presence || "pl_23").to_sym ]
    failures = 0
    treatments.each do |treatment|
      invoice = Ksef::SampleInvoice.build(seller_nip: client.nip, vat_treatment: treatment,
                                          issued_on: Time.now.in_time_zone("Europe/Warsaw").to_date)
      xml = Ksef::Fa3.new(invoice).to_xml
      puts "→ #{treatment}: sending #{invoice.number} to KSeF #{Ksef.environment} as NIP #{client.nip}…"
      result = client.send_invoice(xml)
      failures += 1 unless result.accepted?

      puts "  status:      #{result.status}"
      puts "  KSeF number: #{result.ksef_number || '-'}"
      puts "  reference:   #{result.reference_number || '-'}"
      puts "  error:       #{result.error}" if result.error
      puts "  QR (KOD I):  #{Ksef.qr_url(seller_nip: client.nip, issued_on: invoice.issued_on, xml: xml)}"
    end
    exit(1) if failures.positive?
  end
end
