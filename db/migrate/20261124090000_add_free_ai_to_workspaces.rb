# SCRUM-71 (Kacper, 2026-11-24): an organization with no plan has no AI,
# unless Flosis staff turn on free AI for it in /hidmin. New organizations
# start without it; every organization that exists today keeps working as it
# did (free AI on) until staff turn it off or it buys a plan.
class AddFreeAiToWorkspaces < ActiveRecord::Migration[8.1]
  def up
    add_column :workspaces, :free_ai, :boolean, null: false, default: false
    execute "UPDATE workspaces SET free_ai = TRUE"
  end

  def down
    remove_column :workspaces, :free_ai
  end
end
