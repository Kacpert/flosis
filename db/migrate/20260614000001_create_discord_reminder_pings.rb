class CreateDiscordReminderPings < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_reminder_pings do |t|
      t.references :discord_reminder_recipient, null: false, foreign_key: true,
        index: { name: "index_discord_reminder_pings_on_recipient" }
      t.datetime :sent_at, null: false
      t.timestamps
    end
    add_index :discord_reminder_pings, :sent_at
  end
end
