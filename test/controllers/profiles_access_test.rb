require "test_helper"

# The profile page is the one page everyone reaches — including someone holding
# no permission at all, who is sent here by workshop_landing_path. So it is
# where "what am I allowed to see?" has to be answerable without asking an
# administrator to open Configuration and read a row of toggles aloud.
class ProfilesAccessTest < ActionDispatch::IntegrationTest
  test "a member reads their own role name and what each permission allows" do
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Project Manager"))
    sign_in_as(users(:two))

    get profile_path

    assert_response :success
    assert_match projects(:jira_project).name, response.body
    assert_match "Project Manager", response.body
    # The explanation, not only the switch name.
    assert_match PermissionPreset.description(:reporting), response.body
  end

  test "an administrator is told the privilege is workspace-wide" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))

    get profile_path

    assert_response :success
    assert_match "Administrator", response.body
    assert_match "every project in this workspace", response.body
    # Reaches a project they hold no membership row on.
    assert_match projects(:other_jira_project).name, response.body
  end

  test "someone with no project says so instead of showing an empty table" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)
    project_memberships(:two_elvium).destroy!
    sign_in_as(users(:two))

    get profile_path

    assert_response :success
    assert_match "not on any project", response.body
  end

  # A refused save re-renders this same page, so the card has to be loaded for
  # that render too and not only for show.
  test "the card survives a refused save" do
    sign_in_as(users(:two))

    patch profile_path, params: { user: { name: "", email_address: "two@example.com" } }

    assert_response :unprocessable_entity
    assert_match "Your access", response.body
  end

  test "a person sees only their own projects" do
    workspace_memberships(:client_membership).update!(workspace_admin: false)
    sign_in_as(users(:client_user))

    get profile_path

    assert_response :success
    assert_match projects(:jira_project).name, response.body
    assert_no_match projects(:other_jira_project).name, response.body
  end
end
