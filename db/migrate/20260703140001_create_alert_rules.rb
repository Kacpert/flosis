class CreateAlertRules < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_rules do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :project,   null: false, foreign_key: true
      t.string :name, null: false
      t.text   :prompt, null: false
      t.string :frequency, null: false, default: "daily" # daily|weekdays|mwf|weekly|hourly
      t.string :run_at_time                              # "HH:MM", nil for hourly
      t.references :discord_webhook, null: false, foreign_key: true
      t.boolean :active, null: false, default: true
      t.datetime :last_run_at
      t.timestamps
    end
  end
end
