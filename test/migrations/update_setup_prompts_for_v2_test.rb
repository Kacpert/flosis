require "test_helper"
require Rails.root.join("db/migrate/20261102100600_update_setup_prompts_for_v2")

# The setup's phase prompts move to v2 in the library: only an unedited v1
# text is replaced, by a new version, so staff edits are never overwritten.
# Phases v1 never had are not its concern. (It ran on production on
# 2026-11-02; on a fresh database it writes the current text.)
class UpdateSetupPromptsForV2Test < ActiveSupport::TestCase
  def v1(key) = Rails.root.join("test/fixtures/files/#{key}_v1.txt").read
  def seed = Designs::SetupPrompts::SEEDS.fetch("design_system")
  def migrate = ActiveRecord::Migration.suppress_messages { UpdateSetupPromptsForV2.new.up }

  def entry_at(*bodies)
    entry = LibraryEntry.find_by!(key: seed[:key])
    LibraryEntryVersion.where(library_entry_id: entry.id).delete_all
    bodies.each.with_index(1) { |body, number| entry.library_entry_versions.create!(number: number, body: body) }
    entry
  end

  test "an unedited v1 phase prompt gets the current text as its next version" do
    entry = entry_at(v1(seed[:key]))
    migrate
    assert_equal [ 2, seed[:body].strip ], entry.reload.current_version.then { [ _1.number, _1.body ] }
  end

  test "an edited one stays" do
    entry = entry_at(v1(seed[:key]), "#{v1(seed[:key])}\nOurs.")
    migrate
    assert_equal 2, entry.reload.current_version.number
    assert_includes entry.current_version.body, "Ours."
  end

  test "a phase v1 never had is left alone" do
    entry = LibraryEntry.find_by!(key: "setup-map")
    before = entry.current_version.attributes.slice("number", "body")
    migrate
    assert_equal before, entry.reload.current_version.attributes.slice("number", "body")
  end
end
