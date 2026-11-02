require "test_helper"
require Rails.root.join("db/migrate/20261102100600_update_setup_prompts_for_v2")

# The setup's phase prompts move to v2 in the library: only an unedited v1
# text is replaced, by a new version, so staff edits are never overwritten.
class UpdateSetupPromptsForV2Test < ActiveSupport::TestCase
  def v1(key) = Rails.root.join("test/fixtures/files/#{key}_v1.txt").read

  def entry(key)
    LibraryEntry.find_or_create_by!(key: key) { |e| e.assign_attributes(kind: "base_prompt", name: key, active: true) }.tap do |e|
      LibraryEntryVersion.where(library_entry_id: e.id).delete_all
    end
  end

  test "unedited v1 phase prompts get v2's text as their next version, edited ones stay" do
    seeds = Designs::SetupPrompts::SEEDS.values
    entries = seeds.map { |seed| entry(seed[:key]) }
    entries.each_with_index { |e, i| e.library_entry_versions.create!(number: 1, body: v1(seeds[i][:key])) }
    entries.last.library_entry_versions.create!(number: 2, body: "#{v1(seeds.last[:key])}\nOurs.")

    ActiveRecord::Migration.suppress_messages { UpdateSetupPromptsForV2.new.up }

    assert_equal [ 2, seeds.first[:body].strip ], entries.first.reload.current_version.then { [ _1.number, _1.body ] }
    assert_equal [ 2, seeds.second[:body].strip ], entries.second.reload.current_version.then { [ _1.number, _1.body ] }
    assert_equal 2, entries.last.reload.current_version.number
    assert_includes entries.last.current_version.body, "Ours."
  end
end
