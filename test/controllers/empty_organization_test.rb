require "test_helper"

# A fresh organization from /hidmin has no project and, by default, no Time &
# HR. Its administrator must still reach the Workshop, where the first project
# is created, and nobody in it may be stranded away from their other ones.
class EmptyOrganizationTest < ActionDispatch::IntegrationTest
  setup do
    host! "app.flosis.com"
    @fresh = Workspace.create!(name: "Fresh Co", workshop_enabled: true)
  end

  test "its administrator lands in the Workshop with the New project dialog open" do
    WorkspaceMembership.create!(user: users(:one), workspace: @fresh, workspace_admin: true, time_hr_access: false)
    sign_in_as(users(:one))

    post switch_workspace_path(@fresh), params: { product: "workshop" }
    follow_redirect!
    assert_redirected_to workshop_pipeline_path
    follow_redirect!

    assert_response :success
    assert_select "[data-clar-modal-panel-id-value='new-project']:not(.hidden)"
    assert_select "form[action=?]", switch_workspace_path(workspaces(:one))
  end

  test "its administrator creates the first project" do
    WorkspaceMembership.create!(user: users(:one), workspace: @fresh, workspace_admin: true, time_hr_access: false)
    sign_in_as(users(:one))
    post switch_workspace_path(@fresh), params: { product: "workshop" }

    assert_difference -> { @fresh.projects.count } => 1 do
      post workshop_projects_path, params: { project: { name: "First" } }
    end
    assert_redirected_to workshop_configuration_path(tab: "integrations")
  end

  test "someone on no project there can still switch back to their other organizations" do
    WorkspaceMembership.create!(user: users(:two), workspace: @fresh)
    sign_in_as(users(:two))

    post switch_workspace_path(@fresh)
    follow_redirect!
    assert_redirected_to profile_path
    follow_redirect!

    assert_response :success
    assert_select "form[action=?]", switch_workspace_path(workspaces(:one))
  end
end
