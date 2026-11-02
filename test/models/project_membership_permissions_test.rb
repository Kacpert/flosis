require "test_helper"

# project_memberships already recorded that a person is on a project, with
# their rate. It now also records what they may do there, which keeps one row
# per person per project instead of inventing a parallel table.
class ProjectMembershipPermissionsTest < ActiveSupport::TestCase
  setup { @membership = project_memberships(:two_elvium) }

  test "a new membership starts on the invite defaults" do
    fresh = ProjectMembership.new

    assert fresh.automations
    assert fresh.tasks
    assert fresh.reporting
    assert_not fresh.pricing
    assert_not fresh.designs
    assert_not fresh.briefing_config
    assert_not fresh.configuration
  end

  test "granted lists the switches that are on, in interface order" do
    @membership.update!(PermissionPreset.attributes_for("Product Owner"))

    assert_equal %i[automations tasks designs reporting briefing_config], @membership.granted
  end

  test "the role label is read off the switches" do
    @membership.update!(PermissionPreset.attributes_for("Project Manager"))
    assert_equal "Project Manager", @membership.role_label

    @membership.update!(designs: true, briefing_config: true)
    assert_equal "Product Owner", @membership.role_label

    @membership.update!(pricing: true)
    assert_equal "Custom", @membership.role_label
  end

  test "applying a preset turns switches off as well as on" do
    @membership.update!(PermissionPreset.attributes_for("Administrator"))

    @membership.apply_preset("Project Manager")

    assert_not @membership.configuration, "the preset must clear what it does not grant"
    assert_not @membership.pricing
    assert @membership.tasks
  end

  test "a workspace membership is not an admin until it is told to be" do
    assert_not workspace_memberships(:two_employee).workspace_admin
  end
end
