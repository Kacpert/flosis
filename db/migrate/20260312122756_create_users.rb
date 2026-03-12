class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.string :name, null: false
      t.string :timezone, null: false, default: "UTC"
      t.integer :default_hourly_rate_cents, default: 0

      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
