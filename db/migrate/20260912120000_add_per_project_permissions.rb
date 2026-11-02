# Six switches per person per project, plus the one global privilege that
# survives the old five-value role enum.
#
# Guarded column by column: MySQL commits DDL outside the migration
# transaction, so a failure part-way leaves the earlier columns behind and the
# re-run must not trip over them.
class AddPerProjectPermissions < ActiveRecord::Migration[8.1]
  COLUMNS = {
    automations: true,
    tasks: true,
    reporting: true,
    pricing: false,
    briefing_config: false,
    configuration: false
  }.freeze

  def up
    COLUMNS.each do |name, default|
      next if column_exists?(:project_memberships, name)
      add_column :project_memberships, name, :boolean, default: default, null: false
    end

    unless column_exists?(:workspace_memberships, :workspace_admin)
      add_column :workspace_memberships, :workspace_admin, :boolean, default: false, null: false
    end
  end

  def down
    COLUMNS.each_key do |name|
      remove_column :project_memberships, name if column_exists?(:project_memberships, name)
    end
    if column_exists?(:workspace_memberships, :workspace_admin)
      remove_column :workspace_memberships, :workspace_admin
    end
  end
end
