# A setup run: Flosis staff recreate a project's running app in its design
# repo, in three phases on wip/setup (design system, components, designs),
# and approve the result into master.
#
# design_setups is one run: its phase and status (active until approved),
# who started it, and its crawl of the app — when it was asked for, the
# folder it wrote (under the project's designs_dir), when it finished, and
# why it failed. crawl_error is text, as the other error columns are.
#
# A run's chat belongs to the project, not to a task, so chat_sessions gains
# project_id and task_id may be empty; ChatSession checks that exactly one is
# set.
#
# The three phase prompts are seeded into the library (Designs::SetupPrompts)
# unless an entry has the key.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state. There a create_table is
# one CREATE TABLE with its indexes and foreign keys inside it.
class AddDesignSetups < ActiveRecord::Migration[8.1]
  class Entry < ActiveRecord::Base
    self.table_name = "library_entries"
  end

  class Version < ActiveRecord::Base
    self.table_name = "library_entry_versions"
  end

  def up
    unless table_exists?(:design_setups)
      create_table :design_setups do |t|
        t.references :project, null: false, foreign_key: true
        t.string :phase, null: false, default: "design_system"
        t.string :status, null: false, default: "active"
        t.references :started_by, foreign_key: { to_table: :users, on_delete: :nullify }
        t.string :crawl_dir
        t.text :crawl_error
        t.datetime :crawl_requested_at
        t.datetime :crawled_at
        t.datetime :approved_at
        t.timestamps
      end
    end

    change_column_null :chat_sessions, :task_id, true if column_null?(:chat_sessions, :task_id) == false
    unless column_exists?(:chat_sessions, :project_id)
      add_reference :chat_sessions, :project, null: true, foreign_key: true
    end

    seed_phase_prompts
  end

  def down
    remove_reference :chat_sessions, :project, foreign_key: true if column_exists?(:chat_sessions, :project_id)
    drop_table :design_setups if table_exists?(:design_setups)
  end

  private

  def column_null?(table, column)
    connection.columns(table).find { |c| c.name == column.to_s }&.null
  end

  def seed_phase_prompts
    Entry.reset_column_information
    Version.reset_column_information
    now = Time.current
    Designs::SetupPrompts::SEEDS.each_value do |seed|
      next if Entry.exists?(key: seed[:key])

      entry = Entry.create!(kind: "base_prompt", key: seed[:key], name: seed[:name], description: seed[:description],
                            active: true, created_at: now, updated_at: now)
      Version.create!(library_entry_id: entry.id, number: 1, body: seed[:body].strip, created_at: now)
    end
  end
end
