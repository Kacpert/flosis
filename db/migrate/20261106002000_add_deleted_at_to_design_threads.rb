# A deleted design thread waits 20 days under Deleted, to be restored, before
# it goes for good (Designs::Threads.delete!, Designs::PurgeDeletedThreadsJob).
# A task's thread lets go of its task meanwhile and remembers it for a restore.
class AddDeletedAtToDesignThreads < ActiveRecord::Migration[8.1]
  def change
    change_table :design_threads, bulk: true do |t|
      t.datetime :deleted_at
      t.bigint :restore_task_id
    end
  end
end
