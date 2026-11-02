class AddUserToChatMessages < ActiveRecord::Migration[8.1]
  def change
    # Nullable so historical messages (no author) and assistant messages
    # (no user) can coexist with user-authored ones in shared sessions.
    add_reference :chat_messages, :user, null: true, foreign_key: true
  end
end
