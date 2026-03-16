class MigrateWorkspaceToProjectData < ActiveRecord::Migration[8.1]
  def up
    # Check for orphan time entries (no project)
    orphan_count = execute("SELECT COUNT(*) FROM time_entries WHERE project_id IS NULL").first["COUNT(*)"] rescue 0
    if orphan_count.to_i > 0
      raise "Found #{orphan_count} time entries without a project. Assign them to a project before running this migration."
    end

    # Copy workspace currency to all projects
    execute <<-SQL
      UPDATE projects
      SET currency = (
        SELECT COALESCE(workspaces.default_currency, 'USD')
        FROM workspaces
        WHERE workspaces.id = projects.workspace_id
      )
    SQL

    # Set all time entries to billable before column removal
    execute "UPDATE time_entries SET billable = true WHERE billable = false OR billable IS NULL"

    # Create project_memberships for all user x project combinations
    execute <<-SQL
      INSERT INTO project_memberships (project_id, user_id, hourly_rate_cents, created_at, updated_at)
      SELECT p.id, wm.user_id, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM projects p
      JOIN workspace_memberships wm ON wm.workspace_id = p.workspace_id
      WHERE NOT EXISTS (
        SELECT 1 FROM project_memberships pm
        WHERE pm.project_id = p.id AND pm.user_id = wm.user_id
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
