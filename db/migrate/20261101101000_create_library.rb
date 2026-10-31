# The design library: what every project's design turns run on, kept by Flosis
# staff and never shown to anyone else.
#
# library_entries is one prompt, skill or style pack: its kind, the key it is
# known by (a project names its style pack by key), a name and description for
# the people choosing it, and whether it is in use. Entries are switched off,
# never deleted: a turn records the versions it ran on, and those must stay.
#
# library_entry_versions is an entry's text over time, numbered from 1 per
# entry and written once: editing makes a new version, and so does restoring
# an old one. created_by_id says who wrote it; deleting that user keeps the
# version and forgets the author.
#
# design_turns.library_version_ids is the versions a turn's prompt was made
# of, kept in Flosis, never in the design repo. It is JSON with no default,
# which MySQL could not give it; DesignTurn defaults it to [].
#
# projects.design_style_pack_key is the style pack a project chose, by key.
#
# The base prompt the code carried until now (Designs::Prompt::BASE) becomes
# the library's first entry, designs-base, unless an entry has that key.
#
# Guarded per statement: MySQL commits DDL outside the migration transaction,
# so a failure part-way must leave a re-runnable state. There a create_table is
# one CREATE TABLE with its indexes and foreign keys inside it.
class CreateLibrary < ActiveRecord::Migration[8.1]
  # The tables as they are here, not as the app's models may later have them.
  class Entry < ActiveRecord::Base
    self.table_name = "library_entries"
  end

  class Version < ActiveRecord::Base
    self.table_name = "library_entry_versions"
  end

  def up
    unless table_exists?(:library_entries)
      create_table :library_entries do |t|
        t.string :kind, null: false
        t.string :key, null: false
        t.string :name, null: false
        t.text :description
        t.boolean :active, default: true, null: false
        t.timestamps
        t.index :key, unique: true
      end
    end

    unless table_exists?(:library_entry_versions)
      create_table :library_entry_versions do |t|
        t.references :library_entry, null: false, foreign_key: true, index: false
        t.integer :number, null: false
        t.text :body, null: false
        t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
        t.datetime :created_at, null: false
        t.index [ :library_entry_id, :number ], unique: true
      end
    end

    add_column :design_turns, :library_version_ids, :json unless column_exists?(:design_turns, :library_version_ids)
    add_column :projects, :design_style_pack_key, :string unless column_exists?(:projects, :design_style_pack_key)

    seed_base_prompt
  end

  def down
    remove_column :projects, :design_style_pack_key if column_exists?(:projects, :design_style_pack_key)
    remove_column :design_turns, :library_version_ids if column_exists?(:design_turns, :library_version_ids)
    drop_table :library_entry_versions if table_exists?(:library_entry_versions)
    drop_table :library_entries if table_exists?(:library_entries)
  end

  private

  def seed_base_prompt
    Entry.reset_column_information
    Version.reset_column_information
    return if Entry.exists?(key: "designs-base")

    now = Time.current
    entry = Entry.create!(kind: "base_prompt", key: "designs-base", name: "Designs base prompt",
                          description: "What every design turn is told first.", active: true,
                          created_at: now, updated_at: now)
    Version.create!(library_entry_id: entry.id, number: 1, body: Designs::Prompt::BASE.strip, created_at: now)
  end
end
