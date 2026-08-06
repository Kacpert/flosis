class AddNotifyEnabledToAlertRules < ActiveRecord::Migration[8.1]
  def change
    # Notifications are now opt-in (a switch in the form). When off, the
    # automation runs but posts nothing; the Discord channel is only chosen once
    # notifications are enabled — so the webhook becomes optional.
    add_column :alert_rules, :notify_enabled, :boolean, default: true, null: false
    change_column_null :alert_rules, :discord_webhook_id, true
  end
end
