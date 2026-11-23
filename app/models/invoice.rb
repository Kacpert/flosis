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
end
