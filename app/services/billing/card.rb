# The card, added and changed on Stripe's own secure page (SCRUM-71). Flosis
# keeps only its brand, last four and expiry. A new card is charged straight
# away for a plan payment that failed.
module Billing
  class Card
    def initialize(workspace)
      @workspace = workspace
      @account = workspace.billing
    end

    def page_url(success_url:, cancel_url:)
      Billing.gateway.card_setup_url(@account, success_url: success_url, cancel_url: cancel_url)
    end

    # Saves the card Stripe's page returned with; returns the failed plan
    # charge it tried again, if there was one.
    def save!(session_id, return_url: nil)
      card = Billing.gateway.card_from_setup(@account, session_id)
      @account.update!(stripe_payment_method_id: card.payment_method_id, card_brand: card.brand, card_last4: card.last4,
                       card_exp_month: card.exp_month, card_exp_year: card.exp_year)
      failing = @account.plan_running? && @workspace.billing_charges.plan_charges.failed.order(:id).last
      failing && Charger.new(@workspace).attempt!(failing, off_session: false, return_url: return_url)
    end
  end
end
