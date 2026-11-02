class CreateTaskDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :task_drafts do |t|
      t.references :task, null: false, foreign_key: true
      t.text :content, limit: 16.megabytes - 1
      t.string :source # "ai" by default — leaves room for future "manual" drafts

      t.timestamps
    end

    add_index :task_drafts, [:task_id, :created_at]
  end
end
