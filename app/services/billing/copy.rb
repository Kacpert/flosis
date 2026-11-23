# How Billing, its flashes and its emails say amounts and charges (SCRUM-71),
# in one place so the screen and the inbox use the same words.
module Billing
  module Copy
    module_function

    def money(amount)
      AiCostFormatter.money(amount)
    end

    # "$100", "$1,200": plan prices and top-up amounts.
    def whole(amount)
      ActiveSupport::NumberHelper.number_to_currency(amount, unit: "$", precision: 0)
    end

    def days(charge)
      Proration.label(charge.period_from..charge.period_to)
    end

    # What a charge took, VAT included: "$147.60 charged ($120.00 + VAT for 22–30 Nov)".
    def taken(charge)
      net = charge.vat_usd.positive? ? "#{money(charge.net_usd)} + VAT" : money(charge.net_usd)
      span = charge.period_from && charge.kind.in?(%w[plan upgrade]) ? " for #{days(charge)}" : ""
      "#{money(charge.gross_usd)} charged (#{net}#{span})"
    end

    # Why AI is paused, and the way back, for an organization administrator
    # (admin: true) or anyone else.
    PAUSED = {
      limit: [ "AI paused: limit reached.", "Top up in Billing.", "Ask an admin to top up." ],
      no_plan: [ "AI paused: no plan.", "Choose a plan in Billing.", "Ask an admin to choose a plan." ],
      retry_spent: [ "AI paused: the payment is not through.", "Update the card in Billing.", "Ask an admin to update the card." ],
      unpaid: [ "AI paused: the payment is not through.", "Update the card in Billing.", "Ask an admin to update the card." ]
    }.freeze

    def paused_parts(reason)
      PAUSED.fetch(reason || :limit)
    end

    def paused(reason, admin:)
      title, admin_way, member_way = paused_parts(reason)
      "#{title} #{admin ? admin_way : member_way}"
    end

    # The message box's placeholder: "AI paused: limit reached".
    def paused_short(reason)
      paused_parts(reason).first.delete_suffix(".")
    end

    # The flash after a charge went through.
    def charged(charge)
      invoice = "The invoice is on its way to every admin."
      limit = AiMonthLimit.for(charge.workspace, charge.period_month || Date.current)&.limit_usd
      case charge.kind
      when "plan"
        if charge.period_from == charge.period_month && charge.attempts > 1
          "#{charge.period_month.strftime('%B')}’s payment went through: #{money(charge.gross_usd)} charged, and the full #{money(limit)} limit applies again. #{invoice}"
        else
          "#{charge.plan_name} is active. #{taken(charge)}, and this month’s limit is #{money(limit)}. #{invoice}"
        end
      when "upgrade"
        "Upgraded to #{charge.plan_name}. #{taken(charge)}, and this month’s limit is now #{money(limit)}. #{invoice}"
      else
        "Top-up paid: #{money(charge.net_usd)} added to the balance. #{invoice}"
      end
    end

    # The detail beside an invoice's type: "Starter, November", "Growth
    # upgrade, 22–30 Nov", "Bought by Kacper Admi", "Automatic, 3 of 3".
    def invoice_detail(invoice)
      charge = invoice.billing_charge
      case charge.kind
      when "plan"
        partial = charge.period_from && charge.period_from != charge.period_month
        "#{charge.plan_name}, #{partial ? days(charge) : charge.period_month.strftime('%B')}"
      when "upgrade" then "#{charge.plan_name} upgrade, #{days(charge)}"
      when "top_up" then charge.created_by ? "Bought by #{charge.created_by.name}" : "Bought"
      when "auto_top_up"
        number = charge.automatic_number
        number >= Billing::AUTO_TOP_UPS_PER_MONTH ? "Automatic, #{number} of #{Billing::AUTO_TOP_UPS_PER_MONTH}" : "Automatic"
      end
    end

    # "$200.00 + $46.00 VAT", "$200.00, reverse charge", "$200.00, no Polish VAT".
    def net_line(record)
      vat = Billing::Vat.for(record.respond_to?(:buyer_country_code) ? record.buyer_country_code : nil)
      if record.vat_usd.to_d.positive? then "#{money(record.net_usd)} + #{money(record.vat_usd)} VAT"
      elsif record.vat_treatment == "eu_reverse_charge" then "#{money(record.net_usd)}, reverse charge"
      else "#{money(record.net_usd)}, no Polish VAT"
      end
    end
  end
end
