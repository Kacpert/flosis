class RemoveActivePerTaskUserIndexFromChatSessions < ActiveRecord::Migration[8.1]
  def up
    if index_exists?(:chat_sessions, [:task_id, :user_id, :status], name: "idx_chat_sessions_active_per_task_user")
      remove_index :chat_sessions, name: "idx_chat_sessions_active_per_task_user"
    end
  end

  def down
    add_index :chat_sessions,
              [:task_id, :user_id, :status],
              unique: true,
              name: "idx_chat_sessions_active_per_task_user",
              where: "((status)::text = 'active'::text)"
  end
end
