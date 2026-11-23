# Every morning (SCRUM-71): a failed plan charge due for a retry (days 3, 5
# and 7) is tried again on the card; each failed attempt emails the admins.
# A charge whose outcome is unknown (Stripe unreachable) is asked again with
# the same idempotency key; one still processing is looked up. A 3-D Secure
# step left unfinished for a day is looked up at Stripe first: paid after all,
# it is settled; otherwise the payment is cancelled and the charge given up.
module Billing
  class RetryJob < ApplicationJob
    queue_as :default

    def perform(today = Date.current)
      BillingCharge.plan_charges.failed.where(next_retry_on: ..today).includes(:workspace).find_each do |charge|
        guarded(charge) { Charger.new(charge.workspace).attempt!(charge) }
      end

      BillingCharge.where(status: "pending", updated_at: ...2.minutes.ago).includes(:workspace).find_each do |charge|
        guarded(charge) do
          charger = Charger.new(charge.workspace)
          if charge.stripe_payment_intent_id.present?
            charger.settle!(charge, Billing.gateway.payment_result(charge.stripe_payment_intent_id))
          else
            charger.attempt!(charge)
          end
        end
      end

      BillingCharge.where(status: "requires_action", updated_at: ...1.day.ago).includes(:workspace).find_each do |charge|
        guarded(charge) { Billing::Stale.close!(charge) }
      end
    end

    private

    def guarded(charge)
      yield
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { billing_charge_id: charge.id })
    end
  end
end
