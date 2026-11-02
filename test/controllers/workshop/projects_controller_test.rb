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

  # The toast says the project was created and the redirect goes to "its"
  # Configuration — so the switcher has to be standing in it. A switcher scoped
  # to Jira projects silently fell back to the first project instead, and every
  # key typed on the page that opened was saved onto that one.
  # The dialog takes the keys themselves, not only copies of another
  # project's: the first project of an organization has nothing to copy.
  test "keys typed into the dialog are saved, links included" do
    sign_in_as(users(:one))

    post workshop_projects_path, params: { project: {
      name: "Partner Portal",
      jira_site: "https://acme.atlassian.net/jira/software/projects/PP/boards/1", jira_email: "jane@acme.com",
      jira_api_token: "jira-secret", external_reference: "PP",
      github_repo: "https://github.com/acme/partner-portal.git", github_token: "ghp_secret"
    } }

    project = workspaces(:one).projects.find_by!(name: "Partner Portal")
    assert_equal "acme.atlassian.net", project.jira_site
    assert_equal "jane@acme.com", project.jira_email
    assert_equal "jira-secret", project.jira_api_token
    assert_equal "jira", project.external_type, "a site and a key make it a Jira project"
    assert_equal "acme/partner-portal", project.github_repo
    assert_equal "ghp_secret", project.github_token
  end

  # For now the AI runs on Flosis's own key, so the dialog asks for none.
  test "the dialog does not ask for a Claude key" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_select "[name='project[anthropic_api_key]']", 0
    assert_select "[name='reuse_from[ai]']", 0
  end

  test "a project created with no integrations is the one the page then edits" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))

    post workshop_projects_path, params: { project: { name: "Partner Portal" }, reuse_from: {} }
    follow_redirect!

    assert_response :success
    assert_select 'button[data-action="click->clar-dropdown#toggle"] span', text: "Partner Portal"
  end

  # The dialog that creates projects lives in the Workshop topbar, and
  # require_project_member! refuses a nil current project even to an admin — so
  # a workspace holding no Jira project could not open the Workshop at all, and
  # a new workspace could never get its first project.
  test "a workspace whose only project has no Jira can still open the Workshop" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    projects(:jira_project).update!(archived: true)
    projects(:other_jira_project).update!(archived: true)
    sign_in_as(users(:one))

    get workshop_pipeline_path

    assert_response :success
    assert_select 'button[data-action="click->clar-dropdown#toggle"] span', text: "Internal"
  end

  # The dialog asks for the project key beside the Jira row, and both together
  # are what make the project a Jira project.
  test "a project created with reused Jira credentials and a key is a Jira project" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    projects(:jira_project).update!(jira_site: "acme.atlassian.net", jira_api_token: "jt")
    sign_in_as(users(:one))

    post workshop_projects_path, params: {
      project: { name: "Partner Portal", external_reference: "PP" },
      reuse_from: { "jira" => projects(:jira_project).id }
    }

    project = Project.order(:id).last
    assert_equal "PP", project.external_reference
    assert project.jira_connected?
  end

  # `params[:reuse_from]&.permit!` permitted whatever arrived, and a scalar made
  # `permit!` a NoMethodError and the create a 500.
  test "a reuse_from that is not a hash of integrations is ignored" do
    workspace_memberships(:one_owner).update!(workspace_admin: true)
    sign_in_as(users(:one))

    assert_difference "Project.count", 1 do
      post workshop_projects_path, params: { project: { name: "Partner Portal" }, reuse_from: "1" }
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
