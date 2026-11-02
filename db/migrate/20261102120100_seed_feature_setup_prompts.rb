require "digest"

# The Designs setup runs feature by feature: its turns get the map's prompt,
# the design system's and one feature's (Designs::SetupPrompts). The library
# gets the two new ones, when it has no entry of that key yet, and a
# design-system prompt that is still exactly v2's text gets the new text as
# its next version. One Flosis staff have edited is left as it is, for them to
# bring up to date in the Library.
class SeedFeatureSetupPrompts < ActiveRecord::Migration[8.1]
  # SHA-256 of v2's setup-design-system body, stripped, as
  # UpdateSetupPromptsForV2 stored it.
  V2_DESIGN_SYSTEM_DIGEST = "522c5bc1f8d4dccaa2de04ad9e6a8f74059aaf774b28392c70393ade774a4c54".freeze

  # The tables as they are here, not as the app's models may later have them.
  class Entry < ActiveRecord::Base
    self.table_name = "library_entries"
  end
  class Version < ActiveRecord::Base
    self.table_name = "library_entry_versions"
  end

  def up
    now = Time.current
    %w[map feature].each do |phase|
      seed = Designs::SetupPrompts::SEEDS.fetch(phase)
      next if Entry.exists?(key: seed[:key])

      entry = Entry.create!(kind: "base_prompt", key: seed[:key], name: seed[:name], description: seed[:description],
                            active: true, created_at: now, updated_at: now)
      Version.create!(library_entry_id: entry.id, number: 1, body: seed[:body].strip, created_at: now)
    end

    seed = Designs::SetupPrompts::SEEDS.fetch("design_system")
    entry = Entry.find_by(key: seed[:key]) or return
    current = Version.where(library_entry_id: entry.id).order(number: :desc).first or return
    return unless Digest::SHA256.hexdigest(current.body.to_s) == V2_DESIGN_SYSTEM_DIGEST

    Version.create!(library_entry_id: entry.id, number: current.number + 1, body: seed[:body].strip, created_at: now)
  end

  def down
    # The v2 version stays in the library's history: restore it there.
  end
end
