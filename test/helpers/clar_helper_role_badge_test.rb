require "test_helper"

# The badge names what the switches add up to. It must not invent a role that
# the switches do not describe — "Custom" is the honest answer when someone has
# tuned their own combination.
class ClarHelperRoleBadgeTest < ActionView::TestCase
  include ClarHelper

  test "a preset gets its name and a custom set says so" do
    membership = project_memberships(:two_elvium)

    membership.update!(PermissionPreset.attributes_for("Product Owner"))
    assert_equal "Product Owner", permission_role_badge(membership).last

    membership.update!(pricing: true)
    assert_equal "Custom", permission_role_badge(membership).last
  end

  test "an administrator badge is the warning colour" do
    membership = project_memberships(:two_elvium)
    membership.update!(PermissionPreset.attributes_for("Administrator"))

    assert_equal "clar-badge-warn", permission_role_badge(membership).first
  end
end
