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

  # Eight of production's fifteen people are left holding nothing but a row of
  # this shape: an employee who never had Workshop access, whose project row
  # exists so their hours and their rate attach to a project. Reading it as
  # somewhere to work put a Workshop in their product switcher whose every page
  # refused them and whose landing page is the profile they were already on.
  test "a project row that grants nothing is not somewhere to work" do
    user = users(:workspace_client_user)
    project_memberships(:workspace_client_elvium).destroy!

    assert_not user.reload.can_access_workshop?(@workspace),
               "the only row left grants not one of the six"
  end

  test "one permission is enough to be somewhere to work" do
    user = users(:workspace_client_user)
    project_memberships(:workspace_client_elvium).destroy!
    project_memberships(:workspace_client_internal).update!(tasks: true)

    assert user.reload.can_access_workshop?(@workspace)
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
