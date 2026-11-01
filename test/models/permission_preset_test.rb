require "test_helper"

# A role is a name read off the switches, never a stored value. These pin the
# derivation down, including the two cases that matter most: a set matching no
# preset is "Custom", and nothing granted at all is "No access" — both normal
# states rather than errors, and they must not be confused for each other.
class PermissionPresetTest < ActiveSupport::TestCase
  test "names the three presets" do
    assert_equal "Project Manager", PermissionPreset.label_for(%i[automations tasks reporting])
    assert_equal "Product Owner", PermissionPreset.label_for(%i[automations tasks designs reporting briefing_config])
    assert_equal "Administrator", PermissionPreset.label_for(PermissionPreset::PERMISSIONS)
  end

  test "Product Owners and Administrators get Designs by default, Project Managers do not" do
    assert_includes PermissionPreset::PRESETS["Product Owner"], :designs
    assert_includes PermissionPreset::PRESETS["Administrator"], :designs
    assert_not_includes PermissionPreset::PRESETS["Project Manager"], :designs
    assert_equal "Designs", PermissionPreset.label(:designs)
    assert_equal "Product Owners and Administrators by default", PermissionPreset.default_note(:designs)
  end

  test "the label does not depend on the order it is given" do
    assert_equal "Product Owner", PermissionPreset.label_for(%i[briefing_config reporting designs tasks automations])
  end

  test "the label accepts strings as well as symbols" do
    assert_equal "Project Manager", PermissionPreset.label_for(%w[automations tasks reporting])
  end

  test "anything else is Custom" do
    assert_equal "Custom", PermissionPreset.label_for(%i[tasks])
    assert_equal "Custom", PermissionPreset.label_for(%i[automations tasks reporting pricing])
  end

  # "Custom" claims someone deliberately tuned a combination. An all-off row
  # claims the opposite — nobody has granted anything, and the row is there so
  # an HR-only employee's hours and rate attach to a project.
  test "nothing granted is its own label, not Custom" do
    assert_equal "No access", PermissionPreset.label_for([])
    assert_equal PermissionPreset::NONE, PermissionPreset.label_for(nil)
    assert_not_equal PermissionPreset::CUSTOM, PermissionPreset.label_for([])
  end

  test "Briefing Configuration precedes Configuration in the interface order" do
    order = PermissionPreset::PERMISSIONS
    assert order.index(:briefing_config) < order.index(:configuration)
  end

  test "attributes_for turns a preset into every switch, on or off" do
    attrs = PermissionPreset.attributes_for("Product Owner")

    assert_equal PermissionPreset::PERMISSIONS.sort, attrs.keys.sort
    assert attrs[:briefing_config]
    assert_not attrs[:configuration]
    assert_not attrs[:pricing], "Pricing is off by default for everyone but an Administrator"
  end

  test "an unknown preset falls back to the least privileged one" do
    assert_equal PermissionPreset.attributes_for("Project Manager"),
                 PermissionPreset.attributes_for("Wizard")
  end

  # A switch nobody can explain is a switch nobody should ship. If a seventh
  # permission is ever added, this fails until it has a name and a sentence.
  test "every permission has a name and an explanation" do
    PermissionPreset::PERMISSIONS.each do |permission|
      assert PermissionPreset.label(permission).present?, "#{permission} has no label"
      assert PermissionPreset.description(permission).present?, "#{permission} has no description"
    end

    assert_equal "Briefing Configuration", PermissionPreset.label(:briefing_config)
  end

  # The Designs tab is one of Configuration's: the sentence that says what the
  # switch unlocks has to say so.
  test "Configuration's explanation names Designs" do
    assert_match(/\bDesigns\b/, PermissionPreset.description(:configuration))
  end
end
