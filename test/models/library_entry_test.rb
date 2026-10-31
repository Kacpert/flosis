require "test_helper"

class LibraryEntryTest < ActiveSupport::TestCase
  setup { @entry = LibraryEntry.create!(kind: "skill", key: "forms", name: "Forms") }

  test "revising appends a numbered version" do
    v1 = @entry.revise!(body: "Label every input.", by: users(:one))
    v2 = @entry.revise!(body: "Label every input. Show errors inline.", by: users(:one))
    assert_equal [ 1, 2 ], [ v1.number, v2.number ]
    assert_equal v2, @entry.current_version
    assert_equal users(:one), v2.created_by
  end

  test "revise! with the same body makes no new version" do
    @entry.revise!(body: "Label every input.", by: users(:one))
    @entry.revise!(body: "  Label every input.\n", by: users(:one))
    assert_equal 1, @entry.library_entry_versions.count
  end

  test "restoring an old version makes it current as a new version" do
    v1 = @entry.revise!(body: "one", by: users(:one))
    @entry.revise!(body: "two", by: users(:one))
    v3 = @entry.restore!(v1, by: users(:one))
    assert_equal [ 3, "one" ], [ v3.number, @entry.current_version.body ]
  end

  test "a version of another entry cannot be restored here" do
    other = LibraryEntry.create!(kind: "skill", key: "tables", name: "Tables")
    foreign = other.revise!(body: "Sort every column.", by: users(:one))
    assert_raises(ArgumentError) { @entry.restore!(foreign, by: users(:one)) }
    assert_nil @entry.current_version
  end

  test "keys are lowercase words and dashes, and unique" do
    assert_not LibraryEntry.new(kind: "skill", key: "Bad Key", name: "x").valid?
    assert_not LibraryEntry.new(kind: "skill", key: "forms", name: "dup").valid?
    assert_not LibraryEntry.new(kind: "poem", key: "p", name: "x").valid?
  end

  test "active and of_kind narrow the library" do
    LibraryEntry.create!(kind: "style_pack", key: "calm", name: "Calm", active: false)
    assert_includes LibraryEntry.active.of_kind("skill"), @entry
    assert_empty LibraryEntry.active.of_kind("style_pack")
  end

  test "the base prompt is seeded from the built-in one" do
    base = LibraryEntry.find_by!(key: "designs-base")
    assert_equal Designs::Prompt::BASE.strip, base.current_version.body.strip
  end

  test "a turn records no library versions until it is given some" do
    assert_equal [], DesignTurn.new.library_version_ids
  end
end
