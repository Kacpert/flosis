require "test_helper"

# The switches are the product. Everything else on this screen is a reading of
# them, so the endpoint that flips one has to be exact about who may call it.
class Workshop::ProjectMembersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @membership = project_memberships(:two_elvium)
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "flipping a switch saves it and reports the new role name" do
    @membership.update!(PermissionPreset.attributes_for("Project Manager"))

    patch workshop_project_member_path(@membership),
          params: { permission: "briefing_config", value: "1" }, as: :turbo_stream

    assert_response :success
    assert @membership.reload.briefing_config
    assert_equal "Product Owner", @membership.role_label
  end

  test "an unknown switch is refused" do
    patch workshop_project_member_path(@membership),
          params: { permission: "launch_missiles", value: "1" }, as: :turbo_stream

    assert_response :unprocessable_entity
  end

  test "someone without Configuration cannot flip anyone's switches" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Project Manager"))

    patch workshop_project_member_path(@membership),
          params: { permission: "configuration", value: "1" }, as: :turbo_stream

    assert_response :redirect
    assert_not @membership.reload.configuration
  end

  test "removing a member takes away the project, not the account" do
    assert_difference "ProjectMembership.count", -1 do
      assert_no_difference "User.count" do
        delete workshop_project_member_path(@membership)
      end
    end
  end

  test "a workspace admin cannot be removed from a project" do
    admin_membership = project_memberships(:one_elvium)

    assert_no_difference "ProjectMembership.count" do
      delete workshop_project_member_path(admin_membership)
    end
  end

  test "inviting an unknown address creates the account and the membership" do
    assert_difference [ "User.count", "ProjectMembership.count" ], 1 do
      post workshop_project_members_path, params: {
        name: "Dana Liu", email_address: "dana@acme.io", preset: "Product Owner"
      }
    end

    membership = ProjectMembership.joins(:user).find_by(users: { email_address: "dana@acme.io" })
    assert_equal "Product Owner", membership.role_label
    assert_not membership.user.can_access_time_hr?(workspaces(:one)),
               "a Workshop invitation must not hand out an HR account"
  end

  test "inviting a known address adds them without a second account" do
    assert_no_difference "User.count" do
      post workshop_project_members_path, params: {
        name: "Whatever", email_address: users(:client_user).email_address, preset: "Project Manager"
      }
    end
  end

  test "adding people from another project applies the chosen preset" do
    project_memberships(:client_elvium).destroy!

    post workshop_project_members_path, params: {
      user_ids: [ users(:client_user).id ], preset: "Project Manager"
    }

    membership = ProjectMembership.find_by(user: users(:client_user), project: projects(:jira_project))
    assert_equal "Project Manager", membership.role_label
  end
end
