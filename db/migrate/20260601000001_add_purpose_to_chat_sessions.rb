class AddPurposeToChatSessions < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_sessions, :purpose, :string, null: false, default: "refine"
    add_index :chat_sessions, [:task_id, :purpose, :status],
              name: "index_chat_sessions_on_task_purpose_status"
  end

  def down
    remove_index :chat_sessions, name: "index_chat_sessions_on_task_purpose_status"
    remove_column :chat_sessions, :purpose
  end
end
