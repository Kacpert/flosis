# The idempotency key the charge's last attempt was sent to Stripe with. It
# carries the organization's name, so it is kept rather than worked out
# again: a payment whose outcome was unknown is still found after a rename.
class AddStripeKeyToBillingCharges < ActiveRecord::Migration[8.1]
  def change
    add_column :billing_charges, :stripe_key, :string
  end
end
