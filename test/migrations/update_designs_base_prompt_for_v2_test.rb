require "test_helper"
require Rails.root.join("db/migrate/20261102100500_update_designs_base_prompt_for_v2")

# The base prompt's move to v2 in the library: only an unedited v1 text is
# replaced, by a new version, so staff edits are never overwritten.
class UpdateDesignsBasePromptForV2Test < ActiveSupport::TestCase
  V1 = Rails.root.join("test/fixtures/files/designs_base_prompt_v1.txt").read

  setup do
    @entry = LibraryEntry.find_or_create_by!(key: "designs-base") { |entry| entry.assign_attributes(kind: "base_prompt", name: "Designs base prompt", active: true) }
    LibraryEntryVersion.where(library_entry_id: @entry.id).delete_all
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { UpdateDesignsBasePromptForV2.new.up }
  end

  test "an unedited v1 base prompt gets v2's as its next version" do
    @entry.library_entry_versions.create!(number: 1, body: V1)
    run_migration
    assert_equal [ 2, Designs::Prompt::BASE.strip ], @entry.reload.current_version.then { [ _1.number, _1.body ] }
  end

  test "a base prompt staff have edited is left as it is" do
    @entry.library_entry_versions.create!(number: 1, body: V1)
    @entry.library_entry_versions.create!(number: 2, body: "#{V1}\nOur own rule.")
    run_migration
    assert_equal 2, @entry.reload.current_version.number
  end
end
