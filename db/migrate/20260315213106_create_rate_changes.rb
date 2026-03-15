class CreateRateChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :rate_changes do |t|
      t.references :project_membership, null: false, foreign_key: true
      t.integer :hourly_rate_cents, null: false
      t.integer :previous_rate_cents
      t.references :changed_by, foreign_key: { to_table: :users }
      t.datetime :changed_at, null: false

      t.timestamps
    end
  end
end
