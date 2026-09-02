# Lets an operator arrange the automations by hand. Until now the list was
# ordered by created_at DESC, so the newest rule always jumped to the top and
# the order carried no meaning.
#
# Existing rules are numbered in the order they were already being displayed, so
# nothing appears to move on the deploy that ships this.
class AddPositionToAlertRules < ActiveRecord::Migration[8.1]
  def up
    add_column :alert_rules, :position, :integer

    execute <<~SQL.squish
      UPDATE alert_rules
         SET position = ranked.row_number
        FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY created_at DESC) AS row_number
            FROM alert_rules
        ) AS ranked
       WHERE alert_rules.id = ranked.id
    SQL
  end

  def down
    remove_column :alert_rules, :position
  end
end
