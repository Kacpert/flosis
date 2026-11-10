# What a design turn is doing while it runs, for the chat to show (Designs::
# TurnActivity), and a person's request to stop it, which its job picks up.
class AddActivityToDesignTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :design_turns, :activity, :json
    add_column :design_turns, :stop_requested_at, :datetime
    add_column :design_turns, :stop_requested_by, :string
  end
end
