# An organization's billing (SCRUM-71): who invoices are made out to (their
# country and VAT number decide the VAT), the card Stripe keeps for it, where
# its plan stands, and its automatic top-up. workspaces.ai_plan_id stays the
# current plan; plan_state says whether it is paid for.
#
# none: no plan · pending: a plan chosen (or assigned by Flosis) that is not
# active yet, so nothing is charged and nothing paused · active · cancelling:
# active until the paid month ends, nothing charged after · ended.
class BillingAccount < ApplicationRecord
  PLAN_STATES = %w[none pending active cancelling ended].freeze

  belongs_to :workspace
  belongs_to :pending_ai_plan, class_name: "AiPlan", optional: true

  normalizes :country_code, with: ->(code) { code.to_s.strip.upcase.presence }
  normalizes :vat_number, with: ->(number) { number.to_s.upcase.gsub(/[\s.\-]/, "").presence }
  normalizes :company_name, :street, :postal_code, :city, with: ->(value) { value.to_s.strip.presence }

  validates :plan_state, inclusion: { in: PLAN_STATES }
  validates :auto_top_up_usd, inclusion: { in: Billing::TOP_UP_AMOUNTS }

  # The Billing details form: everything an invoice needs.
  with_options on: :details do
    validates :company_name, :street, :postal_code, :city, :country_code, presence: true
    validates :country_code, inclusion: { in: ->(_) { Billing::Countries.codes } }, allow_blank: true
    validates :vat_number, presence: { message: "is needed: only companies can buy" }, if: -> { country_code.present? && vat.number_required? }
    validate :polish_nip_checksum, if: -> { country_code == "PL" && vat_number.present? }
  end

  def vat
    Billing::Vat.for(country_code)
  end

  def country_name
    Billing::Countries.name(country_code)
  end

  # A Polish NIP without "PL"; an EU VAT number without its country prefix
  # (KSeF wants the two apart).
  def vat_number_digits
    return nil if vat_number.blank?

    prefix = country_code == "GR" ? "EL" : country_code
    vat_number.delete_prefix(prefix.to_s)
  end

  def details_complete?
    [ company_name, street, postal_code, city, country_code ].all?(&:present?) &&
      (!vat.number_required? || vat_number.present?)
  end

  def card?
    stripe_payment_method_id.present?
  end

  def ready?
    details_complete? && card?
  end

  # "Visa •••• 4242, expires 08/28"
  def card_label
    return nil unless card?

    format("%s •••• %s, expires %02d/%02d", card_brand.to_s.titleize, card_last4, card_exp_month.to_i, card_exp_year.to_i % 100)
  end

  # "Visa •••• 4242"
  def card_short
    card? ? "#{card_brand.to_s.titleize} •••• #{card_last4}" : nil
  end

  # The plan is paid for and runs: AI is measured against what was paid.
  def plan_running?
    plan_state.in?(%w[active cancelling])
  end

  def plan_pending?
    plan_state == "pending"
  end

  def cancelling?
    plan_state == "cancelling"
  end

  private

  def polish_nip_checksum
    digits = vat_number.delete_prefix("PL")
    weights = [ 6, 5, 7, 2, 3, 4, 5, 6, 7 ]
    valid = digits.match?(/\A\d{10}\z/) &&
            (weights.each_with_index.sum { |weight, index| weight * digits[index].to_i } % 11) == digits[9].to_i
    errors.add(:vat_number, "is not a valid NIP") unless valid
  end
end
