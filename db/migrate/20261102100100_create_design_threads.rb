# A design thread (Workshop Designs v2): a branch of the project's design repo,
# made from master, and the conversation that changes it. A task has at most
# one; a thread outlives its task.
class CreateDesignThreads < ActiveRecord::Migration[8.1]
  def change
    create_table :design_threads do |t|
      t.references :project, null: false, foreign_key: true
      t.references :task, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.references :author, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :chat_session, foreign_key: { on_delete: :nullify }
      t.string :title, null: false
      t.string :branch
      t.string :status, null: false, default: "open"
      t.string :base_sha
      t.string :merged_sha
      t.datetime :merged_at
      t.string :focus_context
      t.string :focus_screen
      t.text :described_text
      t.string :described_version
      t.timestamps
    end
    add_index :design_threads, [ :project_id, :branch ], unique: true
  end
end
