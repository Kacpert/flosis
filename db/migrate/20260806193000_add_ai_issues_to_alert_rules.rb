class AddAiIssuesToAlertRules < ActiveRecord::Migration[8.1]
  def change
    # A dedicated place for the AI to REPORT problems it hit while running (no
    # permission to comment, a bad/expired key, etc.) — separate from `memory`,
    # so an operator can see WHY an automation is silently not working. AI-managed
    # like memory; viewable (read-only) and clearable in the UI.
    add_column :alert_rules, :ai_issues, :text
  end
end
