# Designs imports: an import keeps its kind (the first one, a re-import on a
# thread, a resync from the app), the app commits it read, a pause for
# Claude's session limit and when it last settled; each feature its queue, its
# own branch, the AI's question and the person's reply, a proposal waiting for
# review and where it came from; and who has opened an import since.
class AddImportsToDesignSetups < ActiveRecord::Migration[8.1]
  def change
    change_table :design_setups, bulk: true do |t|
      t.string :kind, null: false, default: "first"
      t.json :app_commits
      t.datetime :paused_until
      t.datetime :settled_at
      t.bigint :since_setup_id
    end

    change_table :design_setup_features, bulk: true do |t|
      t.integer :attempts, null: false, default: 0
      t.string :branch
      t.datetime :queued_at
      t.text :question
      t.text :reply
      t.json :review
      t.datetime :resets_at
      t.string :source, null: false, default: "map"
      t.text :code_changes
    end

    add_reference :chat_sessions, :design_setup, foreign_key: { on_delete: :nullify }

    create_table :design_import_views do |t|
      t.references :design_setup, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :seen_at, null: false
      t.timestamps
    end
    add_index :design_import_views, %i[design_setup_id user_id], unique: true

    reversible do |dir|
      dir.up do
        execute "UPDATE design_setups SET kind = 'reimport' WHERE design_thread_id IS NOT NULL"
        execute "UPDATE design_setups SET settled_at = finished_at WHERE finished_at IS NOT NULL"
      end
    end
  end
end
