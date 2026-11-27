require "digest"

# 2026-11-27 (Designs speed, Phase 1a): the base prompt now gives a component
# a preview only when it has more than one state, and has a turn re-read only
# the lines it changed, not whole files. Turns take the base prompt from the
# library (designs-base), not from Designs::Prompt::BASE, so a library whose
# base prompt is still exactly the previous text gets the new one as its next
# version; one Flosis staff have edited since is left as it is, for them to
# bring up to date in the Library.
class UpdateDesignsBasePromptForLeanEdits < ActiveRecord::Migration[8.1]
  # SHA-256 of the previous Designs::Prompt::BASE.strip, v2's (2026-11-02).
  PREVIOUS_DIGEST = "40203c654890439576fdc6f585fb70c320e8a7ee5605ad2d00f15fe33e1f6826".freeze

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
    return unless Digest::SHA256.hexdigest(current.body.to_s) == PREVIOUS_DIGEST

    Version.create!(library_entry_id: entry.id, number: current.number + 1, body: Designs::Prompt::BASE.strip, created_at: Time.current)
  end

  def down
    # The previous version stays in the library's history: restore it there.
  end
end
