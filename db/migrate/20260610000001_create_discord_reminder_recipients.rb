class CreateDiscordReminderRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_reminder_recipients do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :discord_user_id, null: false
      t.decimal :min_daily_hours, precision: 4, scale: 1, null: false, default: 4.0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :discord_reminder_recipients, [ :workspace_id, :user_id ], unique: true
  end
end
