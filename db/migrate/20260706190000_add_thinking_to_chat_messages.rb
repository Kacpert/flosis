class AddThinkingToChatMessages < ActiveRecord::Migration[8.1]
  def change
    # The AI's tool-use narration ("investigating the codebase") streamed before
    # the clean answer. Persisted separately from `content` (the answer) so the
    # "Show thinking" toggle survives a page reload.
    add_column :chat_messages, :thinking, :text
  end
end
