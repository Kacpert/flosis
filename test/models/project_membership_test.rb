require "test_helper"

class ProjectMembershipTest < ActiveSupport::TestCase
  test "validates uniqueness of user per project" do
    existing = project_memberships(:one_elvium)
    duplicate = ProjectMembership.new(
      project: existing.project,
      user: existing.user,
      hourly_rate_cents: 5000
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "belongs to project and user" do
    pm = project_memberships(:one_elvium)
    assert_equal projects(:jira_project), pm.project
    assert_equal users(:one), pm.user
  end

  test "defaults hourly_rate_cents to 0" do
    pm = ProjectMembership.new(project: projects(:plain_project), user: users(:two))
    assert_equal 0, pm.hourly_rate_cents
  end
end
