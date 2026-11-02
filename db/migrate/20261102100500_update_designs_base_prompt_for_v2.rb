require "digest"

# Workshop Designs v2 rewrote the base prompt design turns run on
# (Designs::Prompt::BASE): threads, contexts as folders, no manifests. The
# library holds the prompt turns actually get (designs-base), seeded from v1's
# text when the library was made. A library whose base prompt is still exactly
# that text gets v2's as its next version; one Flosis staff have edited since
# is left as it is, for them to bring up to date in the Library.
class UpdateDesignsBasePromptForV2 < ActiveRecord::Migration[8.1]
  # SHA-256 of v1's Designs::Prompt::BASE.strip, as CreateLibrary seeded it.
  V1_DIGEST = "48dde06c2c6e36f03baff381313d20ce3fc0e81e4c54e15ae713830399b1f0a6".freeze

  # The tables as they are here, not as the app's models may later have them.
  class Entry < ActiveRecord::Base
    self.table_name = "library_entries"
  end
  class Version < ActiveRecord::Base
    self.table_name = "library_entry_versions"
  end

  def up
    entry = Entry.find_by(key: "designs-base") or return
    current = Version.where(library_entry_id: entry.id).order(number: :desc).first or return
    return unless Digest::SHA256.hexdigest(current.body.to_s) == V1_DIGEST

    Version.create!(library_entry_id: entry.id, number: current.number + 1, body: Designs::Prompt::BASE.strip, created_at: Time.current)
  end

  def down
    # The v1 version stays in the library's history: restore it there.
  end
end
