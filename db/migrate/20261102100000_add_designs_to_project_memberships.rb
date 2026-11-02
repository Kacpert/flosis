# Designs gets a switch of its own (Workshop Designs v2), on by default for
# Product Owners and Administrators. Rows that already read as one of those —
# any row with Briefing Configuration or Configuration — get it switched on, so
# that their role name stays what it was.
class AddDesignsToProjectMemberships < ActiveRecord::Migration[8.1]
  def up
    add_column :project_memberships, :designs, :boolean, default: false, null: false
    execute "UPDATE project_memberships SET designs = TRUE WHERE briefing_config = TRUE OR configuration = TRUE"
  end

  def down
    remove_column :project_memberships, :designs
  end
end
