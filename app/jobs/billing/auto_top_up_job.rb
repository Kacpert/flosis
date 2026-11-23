# Charges the automatic top-up when it is due (SCRUM-71), off the run that
# used the balance up, so recording a run never waits on Stripe.
module Billing
  class AutoTopUpJob < ApplicationJob
    queue_as :default

    def perform(workspace)
      TopUps.new(workspace).auto!
    end
  end
end
