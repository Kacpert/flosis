# Stands in for Stripe in every test (SCRUM-71): it records what was asked of
# it and succeeds unless a test queues a failure or a 3-D Secure step.
class FakeBillingGateway
  Card = Billing::StripeGateway::Card
  Result = Billing::StripeGateway::ChargeResult

  attr_reader :charges

  def initialize
    @charges = []
    @queued = []
    @results = {}
  end

  def fail_next!(message = "insufficient funds", times: 1)
    times.times { @queued << ->(id) { Result.new(status: :failed, payment_intent_id: id, failure_message: message, redirect_url: nil) } }
  end

  def require_action_next!(url = "https://hooks.stripe.test/3ds")
    @queued << ->(id) { Result.new(status: :requires_action, payment_intent_id: id, failure_message: nil, redirect_url: url) }
  end

  # What payment_result answers for a PaymentIntent after 3-D Secure.
  def settle!(payment_intent_id, status: :succeeded, message: nil)
    @results[payment_intent_id] = Result.new(status: status, payment_intent_id: payment_intent_id, failure_message: message, redirect_url: nil)
  end

  def ensure_customer(account)
    account.update!(stripe_customer_id: "cus_fake_#{account.id}") if account.stripe_customer_id.blank?
    account.stripe_customer_id
  end

  def card_setup_url(account, success_url:, cancel_url:)
    ensure_customer(account)
    "https://checkout.stripe.test/setup?success=#{CGI.escape(success_url)}"
  end

  def card_from_setup(account, session_id)
    raise Billing::NotReady, "That card page was not finished." if session_id == "cs_unfinished"

    Card.new(payment_method_id: "pm_#{session_id}", brand: "visa", last4: "4242", exp_month: 8, exp_year: 2028)
  end

  def charge(account, cents:, description:, idempotency_key:, off_session:, return_url: nil, metadata: {})
    id = "pi_fake_#{@charges.size + 1}"
    @charges << { account: account, cents: cents, description: description, idempotency_key: idempotency_key,
                  off_session: off_session, return_url: return_url, payment_intent_id: id }
    (@queued.shift || ->(pid) { Result.new(status: :succeeded, payment_intent_id: pid, failure_message: nil, redirect_url: nil) }).call(id)
  end

  def payment_result(payment_intent_id)
    @results.fetch(payment_intent_id) { Result.new(status: :succeeded, payment_intent_id: payment_intent_id, failure_message: nil, redirect_url: nil) }
  end
end

module BillingTestHelper
  # A workspace whose admins filled in billing details (a Polish company unless
  # told otherwise) and added a card.
  def billing_ready!(workspace, country: "PL", vat_number: "5261040828")
    account = workspace.billing
    account.update!(company_name: "Acme Sp. z o.o.", street: "ul. Prosta 20", postal_code: "00-850", city: "Warszawa",
                    country_code: country, vat_number: vat_number, vat_checked_at: Time.current,
                    stripe_customer_id: "cus_fake_#{account.id}", stripe_payment_method_id: "pm_fake",
                    card_brand: "visa", card_last4: "4242", card_exp_month: 8, card_exp_year: 2028)
    account
  end

  # The workspace's AI paused: a running $300 plan whose month is used up and
  # no top-up balance.
  def pause_ai!(workspace)
    billing_ready!(workspace)
    Billing::Plans.new(workspace.reload).choose!(billing_plan(name: "Paused plan #{workspace.id}"))
    limit = AiMonthLimit.for(workspace, Date.current).limit_usd
    AiRun.create!(workspace: workspace, area: "agents", automation: "Test", status: "succeeded", cost_usd: limit,
                  price_usd: limit, ran_at: Time.current, funding: "plan")
    workspace.reload
  end

  def billing_plan(name: "Team", price: 300, margin: 30)
    AiPlan.create!(name: name, monthly_price_usd: price, margin_percent: margin)
  end
end
