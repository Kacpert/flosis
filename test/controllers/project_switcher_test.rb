require "test_helper"

# The switcher swaps everything — keys, automations, people — so it has to say
# which project you are about to swap to, not just its name.
class ProjectSwitcherTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    projects(:jira_project).update!(team: "Insights team", github_repo: "acme/survey-platform")
    workspace_memberships(:one_owner).update!(workspace_admin: true)
  end

  test "each project shows its team and repository" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_response :success
    assert_match "Insights team", response.body
    assert_match "acme/survey-platform", response.body
  end

  # No project's subtitle may get emptier than it is today: team and github_repo
  # are blank on every project on the day this ships.
  test "a project without the new fields still names its client and key" do
    client = Client.create!(workspace: workspaces(:one), name: "Acme Industries")
    projects(:jira_project).update!(team: nil, github_repo: nil, client: client)
    sign_in_as(users(:one))

    get workshop_pipeline_path

    assert_response :success
    assert_match "Acme Industries", response.body
    assert_match "ELV", response.body
  end

  # The switcher is the only screen that lists every project at once, so it is
  # the cheapest place to answer "what am I in each of these?".
  test "each project shows the viewer's own role in it" do
    workspace_memberships(:two_employee).update!(workspace_admin: false)
    project_memberships(:two_elvium).update!(PermissionPreset.attributes_for("Product Owner"))
    # A second project with a different role. The account chip already names the
    # role on the project being viewed, so only a badge per row can show this
    # one — asserting on the current project alone would pass without it.
    ProjectMembership.create!(project: projects(:other_jira_project), user: users(:two),
                              **PermissionPreset.attributes_for("Project Manager"))
    sign_in_as(users(:two))

    get workshop_pipeline_path

    assert_response :success
    assert_match "Product Owner", response.body
    assert_match "Project Manager", response.body
  end

  test "only a workspace admin is offered a new project" do
    sign_in_as(users(:one))
    get workshop_pipeline_path
    assert_match "New project", response.body

    workspace_memberships(:one_owner).update!(workspace_admin: false)
    get workshop_pipeline_path
    assert_no_match "New project", response.body
  end
end
