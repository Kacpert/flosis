# Lets an operator arrange the automations by hand. Until now the list was
# ordered by created_at DESC, so the newest rule always jumped to the top and
# the order carried no meaning.
#
# Existing rules are numbered in the order they were already being displayed, so
# nothing appears to move on the deploy that ships this.
#
# The backfill is plain Ruby, not one UPDATE … FROM (SELECT ROW_NUMBER() …):
# development runs Postgres while production runs MySQL, and that syntax is
# Postgres-only. MySQL also commits DDL outside the migration's transaction, so
# a failure halfway leaves the column behind — hence the column_exists? guard,
# which makes a retry work instead of dying on "Duplicate column name".
class AddPositionToAlertRules < ActiveRecord::Migration[8.1]
  def up
    add_column :alert_rules, :position, :integer unless column_exists?(:alert_rules, :position)

    rows = select_all("SELECT id, project_id FROM alert_rules ORDER BY project_id, created_at DESC")
    next_position = Hash.new(0)

    rows.each do |row|
      project_id = row["project_id"]
      next_position[project_id] += 1
      execute("UPDATE alert_rules SET position = #{next_position[project_id].to_i} WHERE id = #{row['id'].to_i}")
    end
  end

  def down
    remove_column :alert_rules, :position
  end
end
