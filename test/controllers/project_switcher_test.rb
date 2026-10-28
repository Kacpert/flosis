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

  # A panel that is not a DESCENDANT of the element carrying the clar-modal
  # controller is never claimed as a target, so the trigger does nothing at all
  # and says nothing about it. Asserting the panel merely exists passes in
  # exactly that state.
  test "the new-project dialog sits inside the modal controller's scope" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_select '[data-controller~="clar-modal"] ' \
                  '[data-clar-modal-target="panel"][data-clar-modal-panel-id-value="new-project"]'
  end

  # Whoever creates the project is deciding what a group of people will be able
  # to see in it, so the dialog spells each preset out instead of naming it.
  test "the new-project dialog says what each preset grants" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    PermissionPreset::PRESETS.each do |label, permissions|
      assert_match label, response.body
      assert_match permissions.map { |permission| PermissionPreset.label(permission) }.to_sentence,
                   response.body
    end
  end

  # Keys are copied from a project the person picks, and Discord owns no column
  # on a project — its webhooks are rows added afterwards — so that one row has
  # nothing to offer but "Set up later".
  test "the new-project dialog offers the workspace's projects as key sources" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_select 'select[name="reuse_from[jira]"] option', text: "Reuse key from Elvium"
    assert_select 'select[name="reuse_from[discord]"] option', 1
  end

  # The chips say "users from other projects", and that is also the rule: an
  # employee with HR access and no project was deliberately kept out of the
  # Workshop, and the screen that creates projects must not be the way back in.
  test "the new-project dialog offers only people already on a project" do
    hr_only = User.create!(name: "Nora Payroll", email_address: "nora@acme.io",
                           password: "password", password_confirmation: "password")
    workspaces(:one).workspace_memberships.create!(user: hr_only, time_hr_access: true,
                                                   workspace_admin: false)
    sign_in_as(users(:one))

    get workshop_pipeline_path

    assert_select 'input[name="user_ids[]"][value=?]', users(:two).id.to_s
    assert_no_match(/Nora Payroll/, response.body,
                    "the dialog must not disclose the staff directory")
  end

  # An administrator's row holds nothing while the flag is on, grants all six
  # the day it comes off, and Configuration refuses to delete it in the
  # meantime — so the mistake of ticking one has no undo.
  test "the new-project dialog does not offer an administrator a row" do
    sign_in_as(users(:one))

    get workshop_pipeline_path

    assert_select 'input[name="user_ids[]"][value=?]', users(:one).id.to_s, false
  end
end
