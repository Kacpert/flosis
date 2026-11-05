# Create Tasks → Setup: a project can switch the Briefing step off, so new
# tasks start straight in Details Gathering. On by default — nothing changes
# for a project until someone turns it off.
class AddBriefingEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :briefing_enabled, :boolean, default: true, null: false
  end
end
