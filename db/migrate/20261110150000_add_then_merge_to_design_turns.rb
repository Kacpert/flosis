# A components turn that Merge queues merges its thread once it succeeds
# (Designs::Threads.merge_or_prepare!): how the merge was asked for, manual
# or auto, waits on the turn.
class AddThenMergeToDesignTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :design_turns, :then_merge, :string
  end
end
