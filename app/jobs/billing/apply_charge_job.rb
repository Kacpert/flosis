# A charge Stripe took whose effect or invoice could not be written at once
# (SCRUM-71): applied again, once, until it holds.
module Billing
  class ApplyChargeJob < ApplicationJob
    queue_as :default

    def perform(charge)
      return unless charge.succeeded?

      Charger.new(charge.workspace).apply!(charge)
    end
  end
end
