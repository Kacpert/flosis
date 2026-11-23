require "test_helper"

# SCRUM-71: Settings › Billing, after designs/admin/billing.html.
class Workshop::BillingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @starter = billing_plan(name: "Starter", price: 200)
    @growth = billing_plan(name: "Growth", price: 600)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
  end

  test "members who aren't admins don't see Billing or Consumption" do
    sign_out
    sign_in_as(users(:two))
    post switch_product_path, params: { product: "workshop" }
    get workshop_billing_path
    assert_response :not_found
    get workshop_consumption_path
    assert_response :not_found
  end

  test "an admin sees Settings with Billing · Consumption first" do
    get workshop_billing_path
    assert_response :success
    assert_select "h1", "Settings"
    assert_select "[data-settings-tabs] a", text: "Billing"
    assert_select "[data-settings-tabs] a", text: "Consumption"
    assert_select "nav a", text: "Settings"
  end

  test "not active yet: no billing details, no card" do
    @workspace.update!(ai_plan: @starter)
    travel_to Time.zone.local(2026, 11, 22, 10) do
      get workshop_billing_path
      assert_select "[data-plan-card]", text: /Starter, \$200 a month · not active yet/
      assert_select "[data-plan-card]", text: /Activating today charges \$60\.00 \+ VAT for 22–30 Nov, and this month’s limit is \$60\.00\. From 1 Dec it is the full \$200\./
      assert_select "[data-not-ready]", "Add billing details to activate your plan"
      assert_select "[data-card-card]", text: /No card yet/
      assert_select "[data-invoices]", text: /No invoices yet/
      assert_select "[data-statements]", text: /No closed month yet\. The first statement comes on 1 Dec 2026\./
      assert_select "button[disabled]", text: "Activate Starter"
    end
  end

  test "billing details are saved; a Polish NIP is checked" do
    patch workshop_billing_details_path, params: { billing_account: { company_name: "Acme Sp. z o.o.", street: "ul. Prosta 20", postal_code: "00-850",
                                                                      city: "Warszawa", country_code: "PL", vat_number: "5261040828" } }
    assert_redirected_to workshop_billing_path
    assert @workspace.billing.reload.details_complete?
    patch workshop_billing_details_path, params: { billing_account: { vat_number: "1234567890" } }
    assert_redirected_to workshop_billing_path(open: "details")
    assert_equal "Vat number is not a valid NIP", flash[:alert]
  end

  test "the card is added on Stripe's page and comes back" do
    post workshop_billing_card_path
    assert_response :see_other
    assert_match "checkout.stripe.test", response.location
    get workshop_billing_card_return_path(session_id: "cs_1")
    assert_equal "Card saved: Visa •••• 4242", flash[:clar_toast]
    assert_equal "pm_cs_1", @workspace.billing.reload.stripe_payment_method_id
  end

  test "activating charges the days left and says so" do
    billing_ready!(@workspace)
    @workspace.update!(ai_plan: @starter)
    travel_to Time.zone.local(2026, 11, 22, 10) do
      post workshop_billing_activate_path
      assert_redirected_to workshop_billing_path
      assert_equal "Starter is active. $73.80 charged ($60.00 + VAT for 22–30 Nov), and this month’s limit is $60.00. The invoice is on its way to every admin.", flash[:notice]
      follow_redirect!
      assert_select "[data-plan-card]", text: /Starter, \$200 a month · next charge 1 Dec 2026/
      assert_select "[data-plan-card]", text: /\$246\.00 with 23% VAT, charged to Visa •••• 4242 on the 1st of each month, for that month\./
      assert_select "[data-invoice='FS/001/11/2026']", text: /Starter, 22–30 Nov/
    end
  end

  test "upgrading to Growth on 22 Nov charges $120 + VAT and the limit becomes $320" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 22, 10) do
      get workshop_billing_path
      assert_select "[data-billing-target=planSummary]", "Growth starts now: $120.00 + VAT is charged today for 22–30 Nov, and this month’s limit becomes $320.00."
      post workshop_billing_plan_path, params: { plan_id: @growth.id }
      assert_equal "Upgraded to Growth. $147.60 charged ($120.00 + VAT for 22–30 Nov), and this month’s limit is now $320.00. The invoice is on its way to every admin.", flash[:notice]
      follow_redirect!
      assert_select "[data-plan-card]", text: /This month’s limit is \$320\.00: \$200\.00 paid on 1 Nov plus \$120\.00 for 22–30 Nov\. From 1 Dec, \$738\.00 with 23% VAT\./
    end
  end

  test "a declined top-up says the bank's reason and charges nothing" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    @billing_gateway.fail_next!("insufficient funds")
    post workshop_billing_top_up_path, params: { amount: 200 }
    assert_equal "The card was declined: insufficient funds. Nothing was charged.", flash[:alert]
    assert_equal 0, Billing::Ledger.balance(@workspace)
  end

  test "3-D Secure sends the admin to the bank and back" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    @billing_gateway.require_action_next!("https://hooks.stripe.test/3ds/1")
    post workshop_billing_top_up_path, params: { amount: 100 }
    assert_redirected_to "https://hooks.stripe.test/3ds/1"
    charge = @workspace.billing_charges.top_ups.sole
    get workshop_billing_payment_return_path(payment_intent: charge.stripe_payment_intent_id)
    assert_equal "Top-up paid: $100.00 added to the balance. The invoice is on its way to every admin.", flash[:notice]
    assert_equal BigDecimal("100"), Billing::Ledger.balance(@workspace)
  end

  test "automatic top-up on, cancel and keep" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    travel_to Time.zone.local(2026, 11, 12, 10) do
      patch workshop_billing_auto_top_up_path, params: { enabled: "1", amount: "100" }
      assert_equal "Automatic top-up on: $100 when the balance runs out", flash[:clar_toast]
      follow_redirect!
      assert_select "[data-top-ups]", text: /\$100 is charged when the limit is reached and the balance runs out, at most 3 times a month · 0 of 3 this month/
      post workshop_billing_cancel_path
      assert_equal "Starter is cancelled. It stays active until 30 Nov 2026, and nothing is charged after.", flash[:notice]
      follow_redirect!
      assert_select "[data-plan-card]", text: /Starter, \$200 a month · ends 30 Nov 2026, nothing charged after/
      post workshop_billing_keep_path
      assert_equal "Starter is kept. Next charge 1 Dec 2026.", flash[:clar_toast]
    end
  end

  test "a failed month shows the retry and the 15% allowance" do
    billing_ready!(@workspace)
    travel_to(Time.zone.local(2026, 11, 1, 6)) { Billing::Plans.new(@workspace.reload).choose!(@starter) }
    @billing_gateway.fail_next!
    travel_to(Time.zone.local(2026, 12, 1, 6)) { Billing::MonthStartJob.perform_now }
    travel_to Time.zone.local(2026, 12, 3, 9) do
      get workshop_billing_path
      assert_select "[data-plan-card]", text: /Starter, \$200 a month · December’s charge failed/
      assert_select "[data-plan-card]", text: /We retry the card until 8 Dec \(day 3 of 7\)\. Until it goes through, AI runs up to \$30\.00, then pauses\./
      assert_select "[data-card-card]", text: /Declined on 1 Dec: insufficient funds\. Change the card and we charge it straight away\./
    end
  end
end
