# A charge whose outcome Stripe couldn't tell (SCRUM-71), looked up by its key
# ten minutes later, once Stripe's search has caught up: settled if Stripe
# took it, failed (nothing charged) if it never got there.
module Billing
  class ResolveChargeJob < ApplicationJob
    queue_as :default

    def perform(charge)
      return unless charge.status == "pending" && charge.stripe_payment_intent_id.blank?

      Charger.new(charge.workspace).resolve_unknown!(charge)
    end
  end
end
