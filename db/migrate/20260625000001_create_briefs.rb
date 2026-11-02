class CreateBriefs < ActiveRecord::Migration[8.1]
  def change
    create_table :briefs do |t|
      t.references :task, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :chat_session, null: true, foreign_key: true
      t.integer :version, null: false, default: 1
      t.text :content, null: false
      t.string :status, null: false, default: "draft"
      t.datetime :briefed_at
      t.timestamps
    end
    add_index :briefs, [:task_id, :version], unique: true
  end
end
