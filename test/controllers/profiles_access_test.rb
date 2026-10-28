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
    assert_select "[data-access-project=?]", projects(:jira_project).id.to_s
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
    # The row SET, not the page text: the timer bar names every active project
    # to an admin, so a name in the body proves nothing about this card.
    assert_select "[data-access-project]", workspaces(:one).projects.active.count
    # Reaches a project they hold no membership row on.
    assert_select "[data-access-project=?]", projects(:other_jira_project).id.to_s
  end

  # Every permission on this card is enforced against current_workshop_project,
  # which comes from workshop_projects — so a row for a project that scope
  # excludes promises access the product cannot hand over.
  test "an archived project is promised to nobody, administrator included" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    projects(:other_jira_project).update!(archived: true)
    sign_in_as(users(:one))

    get profile_path

    assert_response :success
    assert_select "[data-access-project=?]", projects(:other_jira_project).id.to_s, false
    assert_select "[data-access-project]", 2
  end

  test "a member whose only project is archived is told they are on none" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)
    projects(:jira_project).update!(archived: true)
    sign_in_as(users(:two))

    get profile_path

    assert_response :success
    assert_select "[data-access-project]", false
    assert_match "not on any project", response.body
  end

  test "someone with no project says so instead of showing an empty table" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)
    project_memberships(:two_elvium).destroy!
    sign_in_as(users(:two))

    get profile_path

    assert_response :success
    assert_match "not on any project", response.body
  end

  # "You hold all six permissions in every project in this workspace" followed
  # by "you are not on any project" reads as a contradiction. For an admin the
  # empty case is about the workspace, not about them.
  test "an administrator of an empty workspace is told the workspace has no projects" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    workspaces(:one).projects.destroy_all
    sign_in_as(users(:one))

    get profile_path

    assert_response :success
    assert_match "no projects in this workspace yet", response.body
    assert_no_match(/not on any project/, response.body)
  end

  # The sentence explaining a permission you do NOT hold is the one you need in
  # order to ask for it, so a row you lack is muted by colour and never dimmed:
  # opacity put that sentence at ~2:1 against the surface, under the 4.5:1 floor.
  test "a permission you lack is explained at full strength" do
    workspace_memberships(:client_membership).update!(workspace_admin: false)
    sign_in_as(users(:client_user))

    get profile_path

    row = css_select("[data-access-project] dl > div").find do |div|
      div.text.include?(PermissionPreset.label(:pricing))
    end
    assert row, "the card must also explain the permissions this person lacks"
    assert_match PermissionPreset.description(:pricing), row.text
    assert_no_match(/opacity/, row["class"].to_s)
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
    # Card-only facts: the row set, and a role name no preset matches. The
    # project switcher in the layout prints "Elvium" for this person too, so a
    # name in the body is not evidence the card rendered.
    assert_select "[data-access-project]", 1
    assert_select "[data-access-project=?]", projects(:jira_project).id.to_s
    assert_match "Custom", response.body
    assert_no_match projects(:other_jira_project).name, response.body
  end
end
