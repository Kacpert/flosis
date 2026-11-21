# A design turn may answer a person's message with a proposal instead of a
# build (Kacper, 2026-11-21: a direction or a new thing is proposed first), and
# one that did waits for the answer as a plan that asked does.
class AddProposalFlagsToDesignTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :design_turns, :may_propose, :boolean, default: false, null: false
    add_column :design_turns, :proposed, :boolean, default: false, null: false
  end
end
