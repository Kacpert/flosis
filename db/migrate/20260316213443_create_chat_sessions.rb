class CreateChatSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_sessions do |t|
      t.references :task, null: false, foreign_key: true
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :claude_session_id, null: false
      t.string :codebase_path, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end

    add_index :chat_sessions, [:task_id, :user_id, :status], unique: true, name: "idx_chat_sessions_active_per_task_user"
  end
end
