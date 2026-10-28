require "test_helper"

# Creating a project is the workspace privilege. Holding every permission on
# one project must not be enough to create another.
class Workshop::ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
  end

  test "a workspace admin creates a project and lands on its configuration" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))

    assert_difference "Project.count", 1 do
      post workshop_projects_path, params: { project: { name: "Partner Portal" } }
    end

    assert_redirected_to workshop_configuration_path(tab: "integrations")
  end

  test "an administrator on one project cannot create another" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    project_memberships(:one_elvium).update!(PermissionPreset.attributes_for("Administrator"))
    sign_in_as(users(:one))

    assert_no_difference "Project.count" do
      post workshop_projects_path, params: { project: { name: "Partner Portal" } }
    end
  end
end
