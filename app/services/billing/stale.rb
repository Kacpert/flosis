# A charge nobody will finish (SCRUM-71): a 3-D Secure step left for a day,
# or last month's charge still open on the 1st. Stripe is asked first: if the
# money was taken after all, the charge is settled and applied; otherwise a
# payment still waiting is cancelled at Stripe and the charge abandoned (it
# was never invoiced).
module Billing
  module Stale
    module_function

    def close!(charge)
      if charge.stripe_payment_intent_id.present?
        result = Billing.gateway.payment_result(charge.stripe_payment_intent_id)
        return Charger.new(charge.workspace).settle!(charge, result) if result.succeeded?

        Billing.gateway.cancel_payment(charge.stripe_payment_intent_id) if result.requires_action? || result.status == :pending
      end
      charge.update!(status: "abandoned", next_retry_on: nil)
      charge
    end
  end
end
