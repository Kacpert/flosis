# Keeps the previous wording of an automation's prompt.
#
# The prompt is the whole behaviour of a rule, and editing it used to overwrite
# the old text with nothing kept — so "what did this agent say before?" could
# only be answered from a screenshot, or from a copy someone happened to save.
#
# One row per superseded version, newest first; the live text stays on
# alert_rules.prompt. Plain integer FK and no CASCADE, matching the rest of the
# schema — AlertRule declares dependent: :destroy.
class CreateAlertRulePromptVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_rule_prompt_versions do |t|
      t.bigint :alert_rule_id, null: false
      t.text :prompt, null: false
      t.datetime :created_at, null: false

      t.index [ :alert_rule_id, :created_at ]
    end
  end
end
