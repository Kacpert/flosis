require "test_helper"
require "webmock/minitest"

class Billing::StripeGatewayTest < ActiveSupport::TestCase
  setup do
    @account = workspaces(:one).billing
    @account.update!(company_name: "Acme Sp. z o.o.", stripe_customer_id: "cus_1", stripe_payment_method_id: "pm_1")
    @gateway = Billing::StripeGateway.new(api_key: "sk_test_x")
  end

  def intent(status, extra = {})
    { id: "pi_1", object: "payment_intent", status: status }.merge(extra).to_json
  end

  test "an off-session charge confirms at once with the idempotency key" do
    stub = stub_request(:post, "https://api.stripe.com/v1/payment_intents")
      .with { |request|
        body = Rack::Utils.parse_nested_query(request.body)
        body["amount"] == "24600" && body["currency"] == "usd" && body["off_session"] == "true" &&
          body["confirm"] == "true" && body["payment_method"] == "pm_1" && body["customer"] == "cus_1" &&
          request.headers["Idempotency-Key"] == "charge-7"
      }.to_return(body: intent("succeeded"))
    result = @gateway.charge(@account, cents: 24600, description: "Starter, December 2026", idempotency_key: "charge-7", off_session: true)
    assert result.succeeded?
    assert_equal "pi_1", result.payment_intent_id
    assert_requested stub
  end

  test "a decline says the bank's reason in plain words" do
    stub_request(:post, "https://api.stripe.com/v1/payment_intents").to_return(status: 402, body: {
      error: { type: "card_error", code: "card_declined", decline_code: "insufficient_funds",
               message: "Your card has insufficient funds.", payment_intent: { id: "pi_9", object: "payment_intent", status: "requires_payment_method" } }
    }.to_json)
    result = @gateway.charge(@account, cents: 100, description: "x", idempotency_key: "k", off_session: true)
    assert result.failed?
    assert_equal "insufficient funds", result.failure_message
    assert_equal "pi_9", result.payment_intent_id
  end

  test "3-D Secure in the browser returns a redirect" do
    stub_request(:post, "https://api.stripe.com/v1/payment_intents")
      .with { |request| Rack::Utils.parse_nested_query(request.body)["return_url"] == "https://app/return" }
      .to_return(body: intent("requires_action", next_action: { type: "redirect_to_url", redirect_to_url: { url: "https://hooks.stripe.com/3ds" } }))
    result = @gateway.charge(@account, cents: 100, description: "x", idempotency_key: "k", off_session: false, return_url: "https://app/return")
    assert result.requires_action?
    assert_equal "https://hooks.stripe.com/3ds", result.redirect_url
  end

  test "the card page is Checkout in setup mode for the customer" do
    stub = stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |request|
        body = Rack::Utils.parse_nested_query(request.body)
        body["mode"] == "setup" && body["customer"] == "cus_1" && body["success_url"] == "https://app/ok?session_id={CHECKOUT_SESSION_ID}"
      }.to_return(body: { id: "cs_1", object: "checkout.session", url: "https://checkout.stripe.com/c/cs_1" }.to_json)
    assert_equal "https://checkout.stripe.com/c/cs_1",
                 @gateway.card_setup_url(@account, success_url: "https://app/ok?session_id={CHECKOUT_SESSION_ID}", cancel_url: "https://app/billing")
    assert_requested stub
  end

  test "the saved card becomes the default and is read back" do
    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_1}).to_return(body: {
      id: "cs_1", object: "checkout.session", status: "complete", customer: "cus_1",
      setup_intent: { id: "seti_1", object: "setup_intent",
                      payment_method: { id: "pm_2", object: "payment_method", card: { brand: "visa", last4: "4242", exp_month: 8, exp_year: 2028 } } }
    }.to_json)
    default = stub_request(:post, "https://api.stripe.com/v1/customers/cus_1")
      .with(body: hash_including("invoice_settings" => { "default_payment_method" => "pm_2" }))
      .to_return(body: { id: "cus_1", object: "customer" }.to_json)
    card = @gateway.card_from_setup(@account, "cs_1")
    assert_equal [ "pm_2", "visa", "4242", 8, 2028 ], card.to_h.values
    assert_requested default
  end

  test "a customer is made once, from the billing details" do
    @account.update!(stripe_customer_id: nil)
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .with(body: hash_including("name" => "Acme Sp. z o.o."))
      .to_return(body: { id: "cus_new", object: "customer" }.to_json)
    assert_equal "cus_new", @gateway.ensure_customer(@account)
    assert_equal "cus_new", @gateway.ensure_customer(@account.reload)
  end
end
