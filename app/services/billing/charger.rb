# Takes money from an organization's card (SCRUM-71): makes the charge row with
# its VAT, asks Stripe, and on success applies what was bought (the plan's
# month, an upgrade, a top-up) and issues the invoice. A failed charge is only
# recorded: it never creates an invoice. Admins hear about either (BillingMailer).
#
# Once Stripe says a charge succeeded, that is written down on its own first,
# so nothing that goes wrong after it (the effect, the invoice) can lose a
# payment; applying it is then done once (an invoice exists only for an
# applied charge) and retried by Billing::ApplyChargeJob if it fails. Settling
# a charge twice (a 3-D Secure return page reloaded) changes nothing.
module Billing
  class Charger
    def initialize(workspace)
      @workspace = workspace
      @account = workspace.billing
    end

    def charge!(kind:, net:, plan: nil, period: nil, user: nil, off_session: true, return_url: nil)
      attempt!(prepare!(kind: kind, net: net, plan: plan, period: period, user: user), off_session: off_session, return_url: return_url)
    end

    # The charge row, with its VAT, before Stripe is asked.
    def prepare!(kind:, net:, plan: nil, period: nil, user: nil)
      raise NotReady, "Add billing details to activate your plan" unless @account.details_complete?
      raise NotReady, "Add a card first" unless @account.card?

      vat = @account.vat
      BillingCharge.create!(
        workspace: @workspace, kind: kind, net_usd: net, vat_usd: vat.vat_on(net), gross_usd: vat.gross(net),
        vat_rate: vat.rate, vat_treatment: vat.kind.to_s,
        ai_plan: plan, plan_name: plan&.name, plan_price_usd: plan&.monthly_price_usd,
        period_month: period&.begin&.beginning_of_month, period_from: period&.begin, period_to: period&.end,
        created_by: user
      )
    end

    # Tries the card (again). A payment this charge made before is looked at
    # first: one that went through after all is settled instead of charging
    # again, one still waiting for 3-D Secure is cancelled. An attempt whose
    # outcome is unknown keeps its idempotency key, so asking again can never
    # charge twice.
    def attempt!(charge, off_session: true, return_url: nil)
      if charge.stripe_payment_intent_id.present? && !charge.succeeded?
        earlier = Billing.gateway.payment_result(charge.stripe_payment_intent_id)
        return settle!(charge, earlier) if earlier.succeeded?

        Billing.gateway.cancel_payment(charge.stripe_payment_intent_id) if earlier.requires_action?
      end
      result = Billing.gateway.charge(
        @account, cents: charge.cents, description: Invoice.line_name_for(charge),
        idempotency_key: "flosis-charge-#{charge.id}-#{charge.attempts + 1}",
        off_session: off_session, return_url: return_url,
        metadata: { workspace_id: @workspace.id, charge_id: charge.id }
      )
      charge.increment(:attempts) unless result.status == :unknown
      settle!(charge, result)
    end

    # Where a charge stands after Stripe answered, or after 3-D Secure.
    def settle!(charge, result)
      return charge if charge.succeeded?

      charge.stripe_payment_intent_id = result.payment_intent_id if result.payment_intent_id
      case result.status
      when :succeeded then succeed!(charge)
      when :failed then fail!(charge, result.failure_message)
      # A plan month that already failed stays failing while the bank asks
      # for 3-D Secure: the grace and the banner hold until it is paid.
      when :requires_action then charge.update!(status: charge.first_failed_at ? "failed" : "requires_action")
      else charge.update!(status: "pending")
      end
      charge.redirect_url = result.redirect_url
      charge
    end

    # Applies a succeeded charge and issues its invoice, once.
    def apply!(charge)
      return if charge.invoice

      InvoiceCounter.ensure!((charge.succeeded_at || Time.current).in_time_zone.to_date)
      invoice = nil
      BillingCharge.transaction do
        charge.lock!
        next if Invoice.exists?(billing_charge_id: charge.id)

        Effects.apply!(charge, @account)
        invoice = Invoice.issue!(charge)
      end
      Billing.invoice_issued(invoice) if invoice
    rescue StandardError => e
      Rails.error.report(e, handled: true, context: { billing_charge_id: charge.id })
      Billing::ApplyChargeJob.set(wait: 1.minute).perform_later(charge)
    end

    private

    def succeed!(charge)
      won = false
      charge.save! if charge.changed?
      charge.with_lock do
        unless charge.succeeded?
          charge.update!(status: "succeeded", succeeded_at: Time.current, failure_message: nil, next_retry_on: nil)
          won = true
        end
      end
      apply!(charge) if won
    end

    def fail!(charge, message)
      first_attempt = charge.first_failed_at.nil?
      charge.update!(status: "failed", failure_message: message.presence || "the card was declined",
                     first_failed_at: charge.first_failed_at || Time.current)
      # Only a running plan's month is retried; a failed activation leaves the
      # plan not active, for the admin to try again.
      charge.update!(next_retry_on: Retries.next_on(charge)) if charge.kind == "plan" && @account.plan_running?
      Billing.charge_failed(charge, first_attempt: first_attempt)
    end
  end
end
