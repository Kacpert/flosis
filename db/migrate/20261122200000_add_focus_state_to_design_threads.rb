# The state of the screen the person has open (Kacper, 2026-11-22: a page's
# states live in its file, switched by the hash), told to the thread's turns.
class AddFocusStateToDesignThreads < ActiveRecord::Migration[8.1]
  def change
    add_column :design_threads, :focus_state, :string
  end
end
