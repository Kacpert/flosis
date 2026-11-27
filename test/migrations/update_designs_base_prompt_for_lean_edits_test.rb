require "test_helper"
require Rails.root.join("db/migrate/20261127110000_update_designs_base_prompt_for_lean_edits")

# Turns take their base prompt from the library (designs-base), so the leaner
# rules of 2026-11-27 reach them only as its next version: an unedited
# previous text is replaced, and staff edits are never overwritten.
class UpdateDesignsBasePromptForLeanEditsTest < ActiveSupport::TestCase
  PREVIOUS = Rails.root.join("test/fixtures/files/designs_base_prompt_v2.txt").read

  setup do
    @entry = LibraryEntry.find_or_create_by!(key: "designs-base") { |entry| entry.assign_attributes(kind: "base_prompt", name: "Designs base prompt", active: true) }
    LibraryEntryVersion.where(library_entry_id: @entry.id).delete_all
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { UpdateDesignsBasePromptForLeanEdits.new.up }
  end

  test "an unedited base prompt gets the leaner one as its next version, and turns are given it" do
    @entry.library_entry_versions.create!(number: 1, body: PREVIOUS)
    assert_not_includes Designs::Library.compose(projects(:jira_project)).text, "re-read the lines you changed"

    run_migration

    assert_equal [ 2, Designs::Prompt::BASE.strip ], @entry.reload.current_version.then { [ _1.number, _1.body ] }
    assert_includes Designs::Library.compose(projects(:jira_project)).text, "re-read the lines you changed"
  end

  test "a base prompt staff have edited is left as it is" do
    @entry.library_entry_versions.create!(number: 1, body: PREVIOUS)
    @entry.library_entry_versions.create!(number: 2, body: "#{PREVIOUS}\nOur own rule.")

    run_migration

    assert_equal 2, @entry.reload.current_version.number
  end
end
