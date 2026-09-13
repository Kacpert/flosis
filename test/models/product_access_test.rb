require "test_helper"

# The product switcher must mean what it says: you can move between HR and the
# Workshop only when your account exists in both. Two flags on one form could
# disagree; two different facts cannot.
class ProductAccessTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @user = users(:two)
    @membership = workspace_memberships(:two_employee)
  end

  test "HR access is the flag on the workspace membership" do
    @membership.update!(time_hr_access: true)
    assert @user.can_access_time_hr?(@workspace)

    @membership.update!(time_hr_access: false)
    assert_not @user.can_access_time_hr?(@workspace)
  end

  test "Workshop access is having at least one project" do
    assert @user.can_access_workshop?(@workspace)

    ProjectMembership.where(user: @user).destroy_all
    assert_not @user.reload.can_access_workshop?(@workspace)
  end

  test "an archived project is not somewhere to work" do
    ProjectMembership.where(user: @user).where.not(project: projects(:jira_project)).destroy_all
    projects(:jira_project).update!(archived: true)

    assert_not @user.reload.can_access_workshop?(@workspace)
  end

  test "a workspace admin always has the Workshop, with no project rows" do
    ProjectMembership.where(user: @user).destroy_all
    @membership.update!(workspace_admin: true)

    assert @user.reload.can_access_workshop?(@workspace)
  end

  test "both accesses means both products" do
    @membership.update!(time_hr_access: true)

    assert_equal %i[time_hr workshop], @user.accessible_products(@workspace)
  end

  test "one access means one product, and it is the default" do
    @membership.update!(time_hr_access: false)

    assert_equal %i[workshop], @user.accessible_products(@workspace)
    assert_equal :workshop, @user.default_product(@workspace)
  end
end
