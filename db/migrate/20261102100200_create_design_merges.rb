# Every change to a project's master (Workshop Designs v2): a thread merged by
# hand or when its task was Done, or the setup's import. Merge history reads
# these, newest first.
class CreateDesignMerges < ActiveRecord::Migration[8.1]
  def change
    create_table :design_merges do |t|
      t.references :project, null: false, foreign_key: true
      t.references :design_thread, foreign_key: { on_delete: :nullify }
      t.references :task, foreign_key: { on_delete: :nullify }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :sha, null: false
      t.string :title, null: false
      t.string :branch, null: false
      t.string :how, null: false
      t.json :screens
      t.integer :commits, null: false, default: 1
      t.text :summary
      t.json :what_changed
      t.datetime :merged_at, null: false
      t.timestamps
    end
    add_index :design_merges, [ :project_id, :merged_at ]
  end
end
