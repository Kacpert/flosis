require "test_helper"
require Rails.root.join("db/migrate/20261121010100_add_senior_product_designer_skill")

# The senior product designer skill (Kacper, 2026-11-21) comes into the
# library once, switched on; staff tune it there, so a library that has it
# keeps what they made of it.
class AddSeniorProductDesignerSkillTest < ActiveSupport::TestCase
  KEY = "senior-product-designer".freeze

  setup do
    LibraryEntry.where(key: KEY).find_each { |entry| entry.library_entry_versions.delete_all && entry.delete }
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { AddSeniorProductDesignerSkill.new.up }
  end

  test "the skill is added once, active, as version 1" do
    run_migration
    run_migration

    entry = LibraryEntry.find_by!(key: KEY)
    assert_equal [ "skill", "Senior product designer", true ], [ entry.kind, entry.name, entry.active ]
    assert_equal [ 1 ], entry.library_entry_versions.pluck(:number)
    assert_equal Designs::Prompt::SENIOR_DESIGNER_SKILL.strip, entry.current_version.body
    assert_includes Designs::Library.compose(projects(:jira_project)).text, "# Skill: Senior product designer"
  end

  test "a library that already has the skill keeps it as it is" do
    entry = LibraryEntry.create!(key: KEY, kind: "skill", name: "Our designer", active: false)
    entry.library_entry_versions.create!(number: 1, body: "Our own rules.")

    run_migration

    assert_equal [ "Our designer", false, "Our own rules." ], [ entry.reload.name, entry.active, entry.current_version.body ]
  end
end
