require "test_helper"
require Rails.root.join("db/migrate/20261102120100_seed_feature_setup_prompts")

# The setup runs feature by feature: the library gets the map and the feature
# prompts, and an unedited v2 design-system prompt gets its new text as its
# next version. What staff have edited is never overwritten.
class SeedFeatureSetupPromptsTest < ActiveSupport::TestCase
  def migrate = ActiveRecord::Migration.suppress_messages { SeedFeatureSetupPrompts.new.up }
  def seed(phase) = Designs::SetupPrompts::SEEDS.fetch(phase)
  def v2_design_system = Rails.root.join("test/fixtures/files/setup-design-system_v2.txt").read

  def design_system_entry_at(body)
    entry = LibraryEntry.find_by!(key: "setup-design-system")
    LibraryEntryVersion.where(library_entry_id: entry.id).delete_all
    entry.library_entry_versions.create!(number: 2, body: body)
    entry
  end

  test "the map and the feature prompts are seeded when the library lacks them" do
    LibraryEntry.where(key: %w[setup-map setup-feature]).find_each do |entry|
      LibraryEntryVersion.where(library_entry_id: entry.id).delete_all
      entry.delete
    end
    migrate
    %w[map feature].each do |phase|
      entry = LibraryEntry.find_by!(key: seed(phase)[:key])
      assert_equal [ "base_prompt", seed(phase)[:name], true ], [ entry.kind, entry.name, entry.active ]
      assert_equal [ 1, seed(phase)[:body].strip ], [ entry.current_version.number, entry.current_version.body ]
    end
  end

  test "an entry the library has already is left as it is" do
    entry = LibraryEntry.find_by!(key: "setup-map")
    entry.library_entry_versions.create!(number: 7, body: "Ours.")
    migrate
    assert_equal [ 7, "Ours." ], [ entry.reload.current_version.number, entry.current_version.body ]
  end

  test "an unedited v2 design-system prompt gets the new text as its next version" do
    entry = design_system_entry_at(v2_design_system)
    migrate
    assert_equal [ 3, seed("design_system")[:body].strip ], [ entry.reload.current_version.number, entry.current_version.body ]
  end

  test "an edited design-system prompt stays" do
    entry = design_system_entry_at("#{v2_design_system}\nOurs.")
    migrate
    assert_equal 2, entry.reload.current_version.number
    assert_includes entry.current_version.body, "Ours."
  end
end
