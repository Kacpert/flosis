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

  # The Workshop stopped being Jira-shaped: a project with no Jira still has
  # automations, reporting, pricing, users, Discord and PR review. Scoping the
  # switcher to Jira projects hid every other one — including the ones the
  # new-project dialog creates when every integration is left for later.
  test "a project with no Jira is offered in the switcher" do
    workspace_memberships(:one_owner).update!(workspace_admin: false)
    sign_in_as(users(:one))

    get workshop_pipeline_path

    assert_response :success
    assert_select 'form[action=?] input[name="project_id"][value=?]',
                  switch_workshop_project_path, projects(:plain_project).id.to_s
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

  # Keys are copied from a project the person picks — but only from one that has
  # a key of its own. Jira, Figma and the AI key all fall back to the machine's
  # environment or the Claude CLI's login, so a project can work perfectly while
  # its own columns are blank, and offering it would copy nothing in silence.
  # Discord owns no column at all: its webhooks are rows added afterwards.
  test "the new-project dialog offers only projects that hold the key themselves" do
    projects(:jira_project).update!(jira_api_token: "jt")
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_select 'select[name="reuse_from[jira]"] option', text: "Reuse key from Elvium"
    assert_select 'select[name="reuse_from[figma]"] option', 1,
                  "no project holds a Figma token, so there is nothing to reuse"
    assert_select 'select[name="reuse_from[discord]"] option', 1
  end

  # Jira credentials with no project key sync nothing — JiraSyncService has no
  # board to ask about — while the health check still succeeds, so the chip goes
  # green on a project that can never return a ticket. The row that offers the
  # credentials asks for the key as well.
  test "the new-project dialog asks for the Jira project key" do
    sign_in_as(users(:one))
    get workshop_pipeline_path

    assert_select 'input[name="project[external_reference]"]'
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
