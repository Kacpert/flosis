# Every morning (SCRUM-71): a failed plan charge due for a retry (days 3, 5
# and 7) is tried again on the card; each failed attempt emails the admins.
# A charge still waiting on Stripe is asked again, and a 3-D Secure step an
# admin left unfinished for a day is given up (nothing was taken).
module Billing
  class RetryJob < ApplicationJob
    queue_as :default

    def perform(today = Date.current)
      BillingCharge.plan_charges.failed.where(next_retry_on: ..today).includes(:workspace).find_each do |charge|
        Charger.new(charge.workspace).attempt!(charge)
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { billing_charge_id: charge.id })
      end

      BillingCharge.where(status: "pending").where.not(stripe_payment_intent_id: nil).find_each do |charge|
        Charger.new(charge.workspace).settle!(charge, Billing.gateway.payment_result(charge.stripe_payment_intent_id))
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { billing_charge_id: charge.id })
      end

      BillingCharge.where(status: "requires_action", updated_at: ...1.day.ago)
                   .update_all(status: "abandoned", updated_at: Time.current)
    end
  end
end
