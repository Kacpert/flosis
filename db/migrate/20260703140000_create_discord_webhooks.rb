class CreateDiscordWebhooks < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_webhooks do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :channel_name, null: false   # "#dev-alerts"
      t.string :url, null: false
      t.timestamps
    end
  end
end
