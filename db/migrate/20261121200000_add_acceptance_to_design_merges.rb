# Accepting a task's designs (Kacper, 2026-11-21): each merge keeps the preview
# slot its accepted copy lives in, the task's description version it wrote,
# what that version changed, whether the AI's part fell back, and when the
# task's page announced it.
class AddAcceptanceToDesignMerges < ActiveRecord::Migration[8.1]
  def change
    add_column :design_merges, :slot, :string
    add_column :design_merges, :description_version, :integer
    add_column :design_merges, :description_changes, :text
    add_column :design_merges, :described_fallback, :boolean, default: false, null: false
    add_column :design_merges, :announced_at, :datetime
  end
end
