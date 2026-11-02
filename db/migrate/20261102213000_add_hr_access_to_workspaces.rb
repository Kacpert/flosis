# Time & HR becomes something an organization has or hasn't, set by Flosis
# staff in /hidmin. New organizations start without it; the ones that exist
# today all use it, so they keep it.
class AddHrAccessToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :hr_access, :boolean, default: false, null: false
    up_only { execute "UPDATE workspaces SET hr_access = TRUE" }
  end
end
