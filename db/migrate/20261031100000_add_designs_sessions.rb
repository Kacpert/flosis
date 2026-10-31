# Workshop Designs: a Designs chat is an ordinary chat session, and this is what
# it needs that the chat tables do not already have.
#
# chat_messages.kind marks a message the Designs screen draws differently from
# a plain one: the summary of a turn, a new context, a missing requirement, an
# error or a note from the system. It is nullable on purpose. NULL is an
# ordinary message, which is every message that exists today and every one the
# other chats go on writing, so there is nothing to backfill.
#
# design_turns is one run of Claude for one message of the chat: which message
# started it, where it stands (queued, running, succeeded, failed), what kind of
# run it is (a design turn, or one that resolves merge conflicts), why it
# failed and the commit it made. Status and kind are strings with a default, as
# on the other tables, and the error is text because it keeps the CLI's or
# git's own message. [chat_session_id, status] is the index behind "is a turn
# active in this chat?", which the screen asks on every poll.
#
# design_approvals is the history of a task's work being approved into master:
# the number that is also the tag's last segment (approved/<KEY>/<number>), the
# commits either side of the merge, and who approved it. A row is written once
# and never changed, so it has created_at and no updated_at. The unique
# [task_id, number] is what stops two approvals made at the same moment both
# becoming the same version.
#
# Neither table gets an index of its own on the reference its composite index
# starts with: [chat_session_id, status] and [task_id, number] already answer
# any lookup by that reference, and MySQL accepts either as the index its
# foreign key needs.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state. There a create_table is
# one CREATE TABLE with its indexes and foreign keys inside it, so guarding the
# table guards them too and no index is added on its own. Nothing here has a
# JSON column, which MySQL could not give a default.
class AddDesignsSessions < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:chat_messages, :kind)
      add_column :chat_messages, :kind, :string
    end

    unless table_exists?(:design_turns)
      create_table :design_turns do |t|
        t.references :chat_session, null: false, foreign_key: true, index: false
        t.references :chat_message, null: false, foreign_key: true
        t.string :status, null: false, default: "queued"
        t.string :kind, null: false, default: "design"
        t.text :error
        t.string :commit_sha
        t.datetime :started_at
        t.datetime :finished_at
        t.timestamps

        t.index [ :chat_session_id, :status ]
      end
    end

    unless table_exists?(:design_approvals)
      create_table :design_approvals do |t|
        t.references :task, null: false, foreign_key: true, index: false
        t.references :user, null: false, foreign_key: true
        t.integer :number, null: false
        t.string :design_sha, null: false
        t.string :master_sha, null: false
        t.string :tag, null: false
        t.datetime :created_at, null: false

        t.index [ :task_id, :number ], unique: true
      end
    end
  end

  def down
    drop_table :design_approvals if table_exists?(:design_approvals)
    drop_table :design_turns if table_exists?(:design_turns)
    remove_column :chat_messages, :kind if column_exists?(:chat_messages, :kind)
  end
end
