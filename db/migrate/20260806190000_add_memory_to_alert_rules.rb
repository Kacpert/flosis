class AddMemoryToAlertRules < ActiveRecord::Migration[8.1]
  def change
    # Per-automation memory: a free-form JSON string the AI manages itself across
    # runs (what it already scanned/notified, so it doesn't redo work). Stored as
    # :text for MySQL/Postgres portability. The AI prunes stale entries; a hard
    # size cap in code is the backstop.
    add_column :alert_rules, :memory, :text unless column_exists?(:alert_rules, :memory)
  end
end
