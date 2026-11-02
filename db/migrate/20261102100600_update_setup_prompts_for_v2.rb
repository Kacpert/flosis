require "digest"

# Workshop Designs v2 rewrote the setup's three phase prompts
# (Designs::SetupPrompts): design-system/, a folder per context, no
# contexts.json. The library holds the prompts setup turns actually get,
# seeded from v1's text by AddDesignSetups. Each one still exactly that text
# gets v2's as its next version; one Flosis staff have edited is left as it
# is, for them to bring up to date in the Library.
class UpdateSetupPromptsForV2 < ActiveRecord::Migration[8.1]
  # SHA-256 of each v1 seed body, stripped, as AddDesignSetups stored it.
  V1_DIGESTS = {
    "setup-design-system" => "90b2c807218194dfedc68dc8026a1d175c706092b42c62504d2aab179eba125b",
    "setup-components" => "de10ce3cf65db48de6e74ca7e38b24c73e672155c52190b96ab2e4fa50c59826",
    "setup-designs" => "b673667590de0aafdf8171611c2ff5affff16cca6970a61d17ee3a8c5d5bddb9"
  }.freeze

  # The tables as they are here, not as the app's models may later have them.
  class Entry < ActiveRecord::Base
    self.table_name = "library_entries"
  end
  class Version < ActiveRecord::Base
    self.table_name = "library_entry_versions"
  end

  def up
    Designs::SetupPrompts::SEEDS.each_value do |seed|
      entry = Entry.find_by(key: seed[:key]) or next
      current = Version.where(library_entry_id: entry.id).order(number: :desc).first or next
      next unless Digest::SHA256.hexdigest(current.body.to_s) == V1_DIGESTS[seed[:key]]

      Version.create!(library_entry_id: entry.id, number: current.number + 1, body: seed[:body].strip, created_at: Time.current)
    end
  end

  def down
    # The v1 versions stay in the library's history: restore them there.
  end
end
