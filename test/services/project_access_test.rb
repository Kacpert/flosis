require "test_helper"

# One object answers every authorization question, because the alternative —
# six predicates on User, each with its own idea of who counts — is what this
# work is replacing.
class ProjectAccessTest < ActiveSupport::TestCase
  setup do
    @project = projects(:jira_project)
    @other_project = projects(:other_jira_project)
    @member = users(:two)
    @admin = users(:one)
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Project Manager"))
  end

  test "a member holds exactly their switches" do
    access = ProjectAccess.new(@member, @project)

    assert access.can?(:tasks)
    assert access.can?(:automations)
    assert_not access.can?(:configuration)
    assert_not access.can?(:pricing)
  end

  test "a non-member holds nothing" do
    access = ProjectAccess.new(@member, @other_project)

    assert_not access.member?
    PermissionPreset::PERMISSIONS.each { |p| assert_not access.can?(p), "expected no #{p}" }
  end

  test "a workspace admin holds everything, with no membership row at all" do
    assert_nil ProjectMembership.find_by(user: @admin, project: @other_project)
    access = ProjectAccess.new(@admin, @other_project)

    assert access.member?
    PermissionPreset::PERMISSIONS.each { |p| assert access.can?(p), "expected #{p}" }
    assert_equal "Administrator", access.role_label
  end

  test "an unknown permission is refused rather than raising" do
    assert_not ProjectAccess.new(@member, @project).can?(:launch_missiles)
  end

  test "a nil user or a nil project holds nothing" do
    assert_not ProjectAccess.new(nil, @project).can?(:tasks)
    assert_not ProjectAccess.new(@member, nil).can?(:tasks)
  end

  test "the role label of a member is read off their switches" do
    assert_equal "Project Manager", ProjectAccess.new(@member, @project).role_label
  end

  test "User#project_access hands back an access object for that project" do
    assert @member.project_access(@project).can?(:tasks)
    assert_not @member.project_access(@other_project).can?(:tasks)
  end
end
