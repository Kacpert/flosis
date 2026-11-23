# Takes money from an organization's card (SCRUM-71): makes the charge row with
# its VAT, asks Stripe, and on success applies what was bought (the plan's
# month, an upgrade, a top-up) and issues the invoice. A failed charge is only
# recorded: it never creates an invoice. Admins hear about either (BillingMailer).
module Billing
  class Charger
    def initialize(workspace)
      @workspace = workspace
      @account = workspace.billing
    end

    def charge!(kind:, net:, plan: nil, period: nil, user: nil, off_session: true, return_url: nil)
      raise NotReady, "Add billing details to activate your plan" unless @account.details_complete?
      raise NotReady, "Add a card first" unless @account.card?

      vat = @account.vat
      charge = BillingCharge.create!(
        workspace: @workspace, kind: kind, net_usd: net, vat_usd: vat.vat_on(net), gross_usd: vat.gross(net),
        vat_rate: vat.rate, vat_treatment: vat.kind.to_s,
        ai_plan: plan, plan_name: plan&.name, plan_price_usd: plan&.monthly_price_usd,
        period_month: period&.begin&.beginning_of_month, period_from: period&.begin, period_to: period&.end,
        created_by: user
      )
      attempt!(charge, off_session: off_session, return_url: return_url)
    end

    # Tries the card again (a retry, or a new card).
    def attempt!(charge, off_session: true, return_url: nil)
      result = Billing.gateway.charge(
        @account, cents: charge.cents, description: Invoice.line_name_for(charge),
        idempotency_key: "flosis-charge-#{charge.id}-#{charge.attempts + 1}",
        off_session: off_session, return_url: return_url,
        metadata: { workspace_id: @workspace.id, charge_id: charge.id }
      )
      charge.increment(:attempts)
      settle!(charge, result)
    end

    # Where a charge stands after Stripe answered, or after 3-D Secure.
    def settle!(charge, result)
      charge.stripe_payment_intent_id = result.payment_intent_id if result.payment_intent_id
      case result.status
      when :succeeded then succeed!(charge)
      when :failed then fail!(charge, result.failure_message)
      when :requires_action then charge.update!(status: "requires_action")
      else charge.update!(status: "pending")
      end
      charge.redirect_url = result.redirect_url
      charge
    end

    private

    def succeed!(charge)
      invoice = nil
      BillingCharge.transaction do
        charge.update!(status: "succeeded", succeeded_at: Time.current, failure_message: nil, next_retry_on: nil)
        Effects.apply!(charge, @account)
        invoice = Invoice.issue!(charge)
      end
      Billing.invoice_issued(invoice)
    end

    def fail!(charge, message)
      first_attempt = charge.first_failed_at.nil?
      charge.update!(status: "failed", failure_message: message.presence || "the card was declined",
                     first_failed_at: charge.first_failed_at || Time.current)
      charge.update!(next_retry_on: Retries.next_on(charge)) if charge.kind == "plan"
      Billing.charge_failed(charge, first_attempt: first_attempt)
    end
  end
end
