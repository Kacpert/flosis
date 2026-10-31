require "test_helper"

class Designs::LibraryTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @forms = LibraryEntry.create!(kind: "skill", key: "forms", name: "Forms").tap { _1.revise!(body: "Label inputs.", by: nil) }
    @old = LibraryEntry.create!(kind: "skill", key: "old", name: "Old", active: false).tap { _1.revise!(body: "Old.", by: nil) }
    @calm = LibraryEntry.create!(kind: "style_pack", key: "calm", name: "Calm").tap { _1.revise!(body: "Generous whitespace.", by: nil) }
  end

  test "base, active skills and the project's style pack, in that order" do
    @project.update!(design_style_pack_key: "calm")
    composition = Designs::Library.compose(@project)
    assert_match(/\A# Base\n.+# Skill: Forms\nLabel inputs\.\n+# Style pack: Calm\nGenerous whitespace\./m, composition.text)
    assert_not_includes composition.text, "Old."
    assert_equal 3, composition.version_ids.size
  end

  test "an inactive chosen style pack is left out" do
    @project.update!(design_style_pack_key: "calm")
    @calm.update!(active: false)
    assert_not_includes Designs::Library.compose(@project).text, "Generous whitespace."
  end

  test "the texts and version ids line up with the pieces, and skills come in key order" do
    LibraryEntry.create!(kind: "skill", key: "anchors", name: "Anchors").revise!(body: "Link the logo home.", by: nil)
    composition = Designs::Library.compose(@project)
    base = library_entries(:designs_base).current_version
    assert_equal [ base.body, "Link the logo home.", "Label inputs." ], composition.texts
    assert_equal [ base.id, LibraryEntry.find_by!(key: "anchors").current_version.id, @forms.current_version.id ],
                 composition.version_ids
  end

  # Ruling (Plan 3 Task 3): the base prompt carries the rules every turn
  # needs, so switching it off does not take it away.
  test "a switched-off base prompt is still the base" do
    library_entries(:designs_base).update!(active: false)
    assert Designs::Library.compose(@project).text.start_with?("# Base\n#{Designs::Prompt::BASE.strip}")
  end

  test "with no base prompt in the library, the built-in one stands in and records no version" do
    base = library_entries(:designs_base)
    LibraryEntryVersion.where(library_entry: base).delete_all
    composition = Designs::Library.compose(@project)
    assert composition.text.start_with?("# Base\n#{Designs::Prompt::BASE.strip}")
    assert_equal Designs::Prompt::BASE.strip, composition.texts.first
    assert_equal [ @forms.current_version.id ], composition.version_ids
  end
end
