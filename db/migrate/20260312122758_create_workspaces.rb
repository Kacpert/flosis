class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces do |t|
      t.string :name, null: false
      t.integer :default_hourly_rate_cents, default: 0
      t.string :default_currency, null: false, default: "USD", limit: 3
      t.integer :week_start, null: false, default: 1
      t.integer :time_format, null: false, default: 0

      t.timestamps
    end
  end
end
