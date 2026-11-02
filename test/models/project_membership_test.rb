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

  test "destroying workspace membership destroys project memberships" do
    ws_membership = workspace_memberships(:two_employee)
    user = users(:two)
    # two_elvium fixture exists
    assert ProjectMembership.exists?(user: user, project: projects(:jira_project))

    ws_membership.destroy

    assert_not ProjectMembership.exists?(user: user, project: projects(:jira_project))
  end

  test "creates rate_change on create" do
    pm = ProjectMembership.create!(
      project: projects(:plain_project),
      user: users(:two),
      hourly_rate_cents: 5000
    )
    assert_equal 1, pm.rate_changes.count
    rc = pm.rate_changes.first
    assert_equal 5000, rc.hourly_rate_cents
    assert_nil rc.previous_rate_cents
  end

  test "creates rate_change on rate update" do
    pm = project_memberships(:one_elvium)
    assert_difference "RateChange.count", 1 do
      pm.update!(hourly_rate_cents: 20000)
    end
    rc = pm.rate_changes.order(:created_at).last
    assert_equal 20000, rc.hourly_rate_cents
    assert_equal 15000, rc.previous_rate_cents
  end

  test "does not create rate_change when rate unchanged" do
    pm = project_memberships(:one_elvium)
    assert_no_difference "RateChange.count" do
      pm.update!(updated_at: Time.current)
    end
  end
end
