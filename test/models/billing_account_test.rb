require "test_helper"

class BillingAccountTest < ActiveSupport::TestCase
  setup { @account = workspaces(:one).billing }

  def details(**overrides)
    { company_name: "Acme Sp. z o.o.", street: "ul. Prosta 20", postal_code: "00-850",
      city: "Warszawa", country_code: "pl", vat_number: "525-281-23-45" }.merge(overrides)
  end

  test "a Polish company's details are complete with a valid NIP" do
    @account.assign_attributes(details(vat_number: "PL 526-104-08-28"))
    assert @account.valid?(:details), @account.errors.full_messages.to_sentence
    assert_equal "PL", @account.country_code
    assert_equal "PL5261040828", @account.vat_number
    assert_equal "5261040828", @account.vat_number_digits
    assert @account.details_complete?
  end

  test "a NIP with a wrong checksum is refused" do
    @account.assign_attributes(details(vat_number: "5261040829"))
    assert_not @account.valid?(:details)
    assert_includes @account.errors[:vat_number], "is not a valid NIP"
  end

  test "an EU buyer needs a VAT number: only companies can buy" do
    @account.assign_attributes(details(country_code: "DE", vat_number: ""))
    assert_not @account.valid?(:details)
    assert_includes @account.errors[:vat_number], "is needed: only companies can buy"
  end

  test "outside the EU the tax id is optional" do
    @account.assign_attributes(details(country_code: "US", vat_number: nil))
    assert @account.valid?(:details)
    assert_equal :non_eu, @account.vat.kind
  end

  test "the card reads as the design shows it" do
    @account.update!(stripe_payment_method_id: "pm_1", card_brand: "visa", card_last4: "4242", card_exp_month: 8, card_exp_year: 2028)
    assert_equal "Visa •••• 4242, expires 08/28", @account.card_label
    assert_equal "Visa •••• 4242", @account.card_short
  end

  test "a workspace's billing row is made once, pending when Flosis assigned a plan" do
    workspace = workspaces(:two)
    workspace.update!(ai_plan: ai_plans(:scale))
    assert_equal "pending", workspace.billing.plan_state
    assert_equal workspace.billing, workspace.reload.billing
  end
end
