# The library's "Senior product designer" skill (Kacper, 2026-11-21): every
# design thread's turn works as a senior product designer would, with the
# view's purpose first, a person's limited attention, minimal and simple
# solutions, every variant of a value and short replies. It comes in once,
# switched on, from Designs::Prompt::SENIOR_DESIGNER_SKILL; Flosis staff tune
# it in the Library from there, so a library that has it is left as it is.
class AddSeniorProductDesignerSkill < ActiveRecord::Migration[8.1]
  KEY = "senior-product-designer".freeze

  # The tables as they are here, not as the app's models may later have them.
  class Entry < ActiveRecord::Base
    self.table_name = "library_entries"
  end
  class Version < ActiveRecord::Base
    self.table_name = "library_entry_versions"
  end

  def up
    Entry.reset_column_information
    Version.reset_column_information
    return if Entry.exists?(key: KEY)

    now = Time.current
    entry = Entry.create!(key: KEY, kind: "skill", name: "Senior product designer", active: true,
                          description: "How a design thread proposes, places and formats what it adds, and how short it answers.",
                          created_at: now, updated_at: now)
    Version.create!(library_entry_id: entry.id, number: 1, body: Designs::Prompt::SENIOR_DESIGNER_SKILL.strip, created_at: now)
  end

  def down
    # Staff may have tuned it since: it stays, to be switched off in the Library.
  end
end
