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
    keys = []
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .with(body: hash_including("name" => "Acme Sp. z o.o.")) { |request| keys << request.headers["Idempotency-Key"] }
      .to_return(body: { id: "cus_new", object: "customer" }.to_json)
    assert_equal "cus_new", @gateway.ensure_customer(@account)
    assert_equal "cus_new", @gateway.ensure_customer(@account.reload)
    made = @account.created_at.in_time_zone.strftime("%Y%m%d-%H%M%S")
    assert_equal "flosis-#{@account.workspace.name.parameterize}-customer-#{made}-#{@account.id}", keys.sole
  end

  # 2026-11-24: one sandbox serves a developer's database and staging; a bare
  # row id was already taken there with other parameters.
  test "idempotency keys name the organization and tell databases and attempts apart" do
    acme = Workspace.new(id: 3, name: "Acme Inc.")
    charge = Struct.new(:id, :created_at)
    here = charge.new(12, Time.zone.local(2026, 12, 1, 6, 0, 12))
    there = charge.new(12, Time.zone.local(2026, 12, 1, 6, 0, 13))
    key = ->(workspace, record, *parts) { Billing::StripeGateway.idempotency_key(workspace, "auto_top_up", record, *parts) }
    assert_equal "flosis-acme-inc-auto-top-up-20261201-060012-12-1", key.(acme, here, 1)
    assert_not_equal key.(acme, here, 1), key.(acme, there, 1)
    assert_not_equal key.(acme, here, 1), key.(acme, here, 2)
    assert_not_equal key.(acme, here, 1), key.(Workspace.new(id: 4, name: "Beta"), here, 1)
    assert_equal key.(acme, here, 1), key.(acme, here, 1)
  end

  test "the organization in a key: Polish letters, a long name, a name with no letters" do
    slug = ->(name) { Billing::StripeGateway.organization_slug(Workspace.new(id: 7, name: name)) }
    assert_equal "zolta-lodz-sp-z-o-o", slug.("Żółta Łódź Sp. z o.o.")
    assert_equal "a" * 40, slug.("a" * 60)
    assert_equal "a" * 39, slug.("a" * 39 + " bcd")
    assert_equal "organization-7", slug.("株式会社")
  end
end
