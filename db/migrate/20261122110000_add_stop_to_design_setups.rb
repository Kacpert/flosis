# Designs imports (Kacper, 2026-11-22): an import can be stopped from its
# page. A stopped import is failed, with when and by whom, so that its page
# says so and Resume knows what the stop interrupted.
class AddStopToDesignSetups < ActiveRecord::Migration[8.1]
  def change
    add_column :design_setups, :stopped_at, :datetime
    add_reference :design_setups, :stopped_by, foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
