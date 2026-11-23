# SCRUM-71: a failed automatic top-up pauses AI until the card is changed or
# someone tops up by hand; when the card was last saved tells which came last.
class AddCardSavedAtToBillingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :billing_accounts, :card_saved_at, :datetime
  end
end
