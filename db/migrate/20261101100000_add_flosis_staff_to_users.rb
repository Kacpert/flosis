# users.flosis_staff marks the people of Flosis the company: the team that
# keeps the design library (base prompt, skills, style packs) every project's
# design turns run on. It is not a workspace role. A workspace admin is not
# staff, and staff see no workspace they are not a member of. It is set from
# the command line (flosis:staff:grant), never from the app.
#
# Guarded: MySQL commits DDL outside the migration transaction, so a failure
# part-way must leave a re-runnable state.
class AddFlosisStaffToUsers < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:users, :flosis_staff)

    add_column :users, :flosis_staff, :boolean, default: false, null: false
  end

  def down
    remove_column :users, :flosis_staff if column_exists?(:users, :flosis_staff)
  end
end
