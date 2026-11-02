class RenameWorkspaceMembershipMemberRoleToEmployee < ActiveRecord::Migration[8.1]
  def up
    # Role enum: member(0) -> employee(0), admin(1), owner(2), add client(3)
    # Since employee keeps the same integer value (0), no data migration needed
    # for existing member rows. Just need to ensure the enum name change in model.
  end

  def down
    # No-op since we're only renaming the enum label, not changing data
  end
end
