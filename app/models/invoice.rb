# A VAT invoice for one succeeded charge (SCRUM-71). It exists only once the
# money is taken, is numbered PREFIX/YYYY/MM/NNNN without gaps, carries a
# snapshot of who it was made out to, and goes to KSeF; once KSeF gives it a
# number, its PDF (with that number and the QR code) is emailed to every admin.
class Invoice < ApplicationRecord
  KSEF_STATUSES = %w[pending sent failed].freeze

  belongs_to :workspace
  belongs_to :billing_charge

  validates :number, presence: true, uniqueness: true
  validates :ksef_status, inclusion: { in: KSEF_STATUSES }

  scope :newest_first, -> { order(issued_on: :desc, id: :desc) }

  # Issues the invoice for a charge that went through. Idempotent per charge.
  def self.issue!(charge)
    return charge.invoice if charge.invoice

    account = charge.workspace.billing_account
    issued_on = (charge.succeeded_at || Time.current).in_time_zone.to_date
    create!(
      workspace: charge.workspace, billing_charge: charge,
      number: InvoiceCounter.next_number!(issued_on),
      issued_on: issued_on, sold_on: issued_on,
      kind: charge.kind, line_name: line_name_for(charge),
      buyer_name: account.company_name, buyer_street: account.street,
      buyer_postal_code: account.postal_code, buyer_city: account.city,
      buyer_country_code: account.country_code, buyer_vat_number: account.vat_number,
      net_usd: charge.net_usd, vat_usd: charge.vat_usd, gross_usd: charge.gross_usd,
      vat_rate: charge.vat_rate, vat_treatment: charge.vat_treatment
    )
  rescue ActiveRecord::RecordNotUnique
    charge.reload.invoice
  end

  # "Starter, November 2026", "Growth upgrade, 22–30 Nov", "Top-up",
  # "Automatic top-up".
  def self.line_name_for(charge)
    case charge.kind
    when "plan"
      month = charge.period_month.strftime("%B %Y")
      partial = charge.period_from && charge.period_from != charge.period_month
      partial ? "#{charge.plan_name}, #{Billing::Proration.label(charge.period_from..charge.period_to)} #{charge.period_month.year}" : "#{charge.plan_name}, #{month}"
    when "upgrade"
      "#{charge.plan_name} upgrade, #{Billing::Proration.label(charge.period_from..charge.period_to)} #{charge.period_month.year}"
    when "top_up" then "Top-up"
    when "auto_top_up" then "Automatic top-up"
    end
  end

  def type_label
    billing_charge.type_label
  end

  def vat
    Billing::Vat.for(buyer_country_code)
  end

  def sent_to_ksef?
    ksef_status == "sent"
  end

  def pdf_filename
    "#{number.tr('/', '-')}.pdf"
  end

  # The VAT in PLN at the NBP rate of the working day before the invoice,
  # taken once (only when there is VAT to convert).
  def take_exchange_rate!
    return unless vat_usd.positive? && exchange_rate.nil?

    rate = NbpRate.usd_before(issued_on)
    update!(exchange_rate: rate.mid, exchange_rate_date: rate.date, exchange_rate_table: rate.table,
            vat_pln: (vat_usd * rate.mid).round(2))
  end

  # The invoice as the KSeF module takes it.
  def to_ksef
    seller = Billing::Seller
    raise Ksef::ConfigurationError, "The seller's details are not set (INVOICE_SELLER_*)" unless seller.configured?

    Ksef::Invoice.new(
      number: number, issued_on: issued_on, sold_on: sold_on, currency: "USD",
      seller: Ksef::Party.new(name: seller.name, nip: seller.nip, country_code: "PL",
                              address_line1: seller.street, address_line2: "#{seller.postal_code} #{seller.city}"),
      buyer: ksef_buyer, vat_treatment: vat_treatment.to_sym,
      lines: [ Ksef::Line.new(name: line_name, net: net_usd, vat_rate: (vat_rate.to_i if vat_usd.positive?), vat: vat_usd, gross: gross_usd) ],
      net: net_usd, vat: vat_usd, gross: gross_usd,
      exchange_rate: exchange_rate, exchange_rate_date: exchange_rate_date, vat_pln: vat_pln,
      paid_on: billing_charge.succeeded_at&.in_time_zone&.to_date || issued_on
    )
  end

  # The KOD I link printed as the invoice's QR code: the exact XML KSeF took.
  def qr_url
    ksef_xml && Ksef.qr_url(seller_nip: Billing::Seller.nip, issued_on: issued_on, xml: ksef_xml)
  end

  # "167.96 zł at the NBP rate of 3.6512 from 30 Oct 2026"
  def vat_pln_line
    return nil unless vat_pln

    "#{format('%.2f', vat_pln)} zł at the NBP rate of #{format('%.4f', exchange_rate)} from #{exchange_rate_date.strftime('%-d %b %Y')}"
  end

  # Before KSeF has it, an invoice whose buyer was wrong can take the
  # organization's corrected details (staff fix them, then Retry).
  def refresh_buyer!
    account = workspace.billing_account
    update!(buyer_name: account.company_name, buyer_street: account.street, buyer_postal_code: account.postal_code,
            buyer_city: account.city, buyer_country_code: account.country_code, buyer_vat_number: account.vat_number,
            ksef_xml: nil, ksef_reference: nil)
  end

  private

  def ksef_buyer
    address = { address_line1: buyer_street, address_line2: [ buyer_postal_code, buyer_city ].compact.join(" ") }
    case vat_treatment
    when "pl_23" then Ksef::Party.new(name: buyer_name, nip: buyer_vat_number.to_s.delete_prefix("PL"), country_code: "PL", **address)
    when "eu_reverse_charge"
      number = buyer_vat_number.to_s
      prefix = buyer_country_code == "GR" ? "EL" : buyer_country_code
      Ksef::Party.new(name: buyer_name, eu_vat_number: number.start_with?(prefix) ? number : "#{prefix}#{number}", country_code: buyer_country_code, **address)
    else Ksef::Party.new(name: buyer_name, tax_id: buyer_vat_number.presence, country_code: buyer_country_code, **address)
    end
  end
end
