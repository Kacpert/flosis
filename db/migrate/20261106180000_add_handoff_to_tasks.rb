# A task started from another task's conversation (the chat's "New task"):
# the task it came from, the conversation it came from, and what the AI handed
# over from that conversation for this task (TaskHandoff). The handoff is
# empty until it is written, which this task's first chat does.
class AddHandoffToTasks < ActiveRecord::Migration[8.1]
  def change
    add_reference :tasks, :spun_off_from, foreign_key: { to_table: :tasks, on_delete: :nullify }
    add_reference :tasks, :handoff_chat_session, foreign_key: { to_table: :chat_sessions, on_delete: :nullify }
    add_column :tasks, :handoff, :text
  end
end
