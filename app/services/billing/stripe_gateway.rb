# Stripe, as Flosis uses it (SCRUM-71): it keeps the card, entered on Stripe's
# own Checkout page (mode "setup"), and takes the amounts Flosis computed as
# PaymentIntents. No Stripe subscriptions or invoices: the plan, proration,
# retries and invoicing are Flosis's. Every charge is confirmed at once, so no
# webhooks are needed; a charge an admin makes in the browser may return
# through 3-D Secure (return_url).
#
# STRIPE_SECRET_KEY, falling back to STRIPE_SANDBOX_SECRET_KEY (test mode).
module Billing
  class StripeGateway
    Card = Data.define(:payment_method_id, :brand, :last4, :exp_month, :exp_year)
    # status: :succeeded · :failed (failure_message is the bank's reason, in
    # plain words) · :requires_action (redirect_url finishes 3-D Secure) ·
    # :pending (still processing).
    ChargeResult = Data.define(:status, :payment_intent_id, :failure_message, :redirect_url) do
      def succeeded? = status == :succeeded
      def failed? = status == :failed
      def requires_action? = status == :requires_action
    end

    # The bank's reasons as the emails and Billing say them ("The bank said: …").
    DECLINES = {
      "insufficient_funds" => "insufficient funds",
      "expired_card" => "the card has expired",
      "incorrect_cvc" => "the security code is wrong",
      "card_velocity_exceeded" => "the card's limit is reached",
      "authentication_required" => "the bank wants the payment confirmed",
      "lost_card" => "the card was declined",
      "stolen_card" => "the card was declined",
      "do_not_honor" => "the card was declined",
      "generic_decline" => "the card was declined",
      "card_declined" => "the card was declined",
      "processing_error" => "the bank could not process it"
    }.freeze

    def self.api_key
      ENV["STRIPE_SECRET_KEY"].presence || ENV["STRIPE_SANDBOX_SECRET_KEY"].presence
    end

    def initialize(api_key: self.class.api_key)
      @api_key = api_key
    end

    def ensure_customer(account)
      return account.stripe_customer_id if account.stripe_customer_id.present?

      customer = client.v1.customers.create(
        { name: account.company_name || account.workspace.name,
          email: account.workspace.admin_users.order(:id).pick(:email_address),
          metadata: { workspace_id: account.workspace_id } },
        { idempotency_key: "flosis-customer-#{account.id}" }
      )
      account.update!(stripe_customer_id: customer.id)
      customer.id
    end

    # Stripe's secure page where the card is added or changed.
    def card_setup_url(account, success_url:, cancel_url:)
      client.v1.checkout.sessions.create(
        mode: "setup", customer: ensure_customer(account), currency: "usd",
        payment_method_types: [ "card" ], success_url: success_url, cancel_url: cancel_url,
        metadata: { workspace_id: account.workspace_id }
      ).url
    end

    # The card saved on the Checkout page, made the customer's default.
    def card_from_setup(account, session_id)
      session = client.v1.checkout.sessions.retrieve(session_id, { expand: [ "setup_intent.payment_method" ] })
      unless session.customer == account.stripe_customer_id && session.status == "complete"
        raise Billing::NotReady, "That card page was not finished."
      end

      method = session.setup_intent.payment_method
      client.v1.customers.update(account.stripe_customer_id, { invoice_settings: { default_payment_method: method.id } })
      Card.new(payment_method_id: method.id, brand: method.card.brand, last4: method.card.last4,
               exp_month: method.card.exp_month, exp_year: method.card.exp_year)
    end

    def charge(account, cents:, description:, idempotency_key:, off_session:, return_url: nil, metadata: {})
      params = {
        amount: cents, currency: "usd", customer: account.stripe_customer_id,
        payment_method: account.stripe_payment_method_id, payment_method_types: [ "card" ],
        confirm: true, description: description, metadata: metadata
      }
      off_session ? params[:off_session] = true : params[:return_url] = return_url
      result(client.v1.payment_intents.create(params, { idempotency_key: idempotency_key }))
    rescue Stripe::CardError => e
      ChargeResult.new(status: :failed, payment_intent_id: e.error&.payment_intent&.id,
                       failure_message: reason(e.error&.decline_code || e.code, e.message), redirect_url: nil)
    rescue Stripe::StripeError => e
      Rails.logger.error("[Billing::StripeGateway] #{e.class}: #{e.message}")
      ChargeResult.new(status: :failed, payment_intent_id: nil,
                       failure_message: "the payment could not be made (#{e.class.name.demodulize})", redirect_url: nil)
    end

    def payment_result(payment_intent_id)
      result(client.v1.payment_intents.retrieve(payment_intent_id))
    end

    private

    def client
      raise Billing::NotReady, "Payments are not set up (no Stripe key)." if @api_key.blank?

      @client ||= Stripe::StripeClient.new(@api_key)
    end

    def result(intent)
      case intent.status
      when "succeeded"
        ChargeResult.new(status: :succeeded, payment_intent_id: intent.id, failure_message: nil, redirect_url: nil)
      when "requires_action"
        ChargeResult.new(status: :requires_action, payment_intent_id: intent.id, failure_message: nil,
                         redirect_url: intent.next_action&.redirect_to_url&.url)
      when "processing"
        ChargeResult.new(status: :pending, payment_intent_id: intent.id, failure_message: nil, redirect_url: nil)
      else
        error = intent.last_payment_error
        ChargeResult.new(status: :failed, payment_intent_id: intent.id,
                         failure_message: reason(error&.decline_code || error&.code, error&.message), redirect_url: nil)
      end
    end

    def reason(code, message)
      DECLINES[code.to_s] || message.presence&.delete_suffix(".")&.sub(/\AYour card /, "the card ") || "the card was declined"
    end
  end
end
