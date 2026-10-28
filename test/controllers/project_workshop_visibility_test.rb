require "test_helper"

# A Time & HR project is somewhere for hours to land. Most of them have no
# board, no repository and nobody doing Workshop work — they only ever filled
# the project switcher. `show_in_workshop` is how a project says it belongs in
# Flosis, and the rule that matters is that saying no never touches time
# tracking: the timer and the timesheet still offer every project.
class ProjectWorkshopVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    workspace_memberships(:two_employee).update!(workspace_admin: true, time_hr_access: true)
    @stub = projects(:hr_only_project)
    sign_in_as(@user)
  end

  test "a hidden project is not offered in the Workshop project switcher" do
    get workshop_pipeline_path

    assert_response :success
    assert_select "[data-project-switcher]", minimum: 0 do
      assert_select "*", text: /#{@stub.name}/, count: 0
    end
    assert_no_match(/#{@stub.name}/, response.body,
                    "a project kept out of Flosis must not appear anywhere in a Workshop page")
  end

  test "a visible project still is" do
    get workshop_pipeline_path

    assert_response :success
    assert_match(/#{projects(:jira_project).name}/, response.body)
  end

  # The whole point of the stubs. Scoped to the form's own project control so
  # the assertion cannot be satisfied by the name appearing in a heading or a
  # running timer elsewhere on the page.
  test "a hidden project is still available to log time against" do
    get new_time_entry_path

    assert_response :success
    # No message argument: with substitutions, assert_select reads a trailing
    # string as the element's expected TEXT, not as the failure message.
    assert_select "select[name=?] option[value=?]", "time_entry[project_id]", @stub.id.to_s
  end

  test "a hidden project is still offered by the timer" do
    get time_entries_path

    assert_response :success
    assert_select "select[name=?] option[value=?]", "project_id", @stub.id.to_s
  end

  # Hidden wins over the Jira board too: credentials left on a project someone
  # has since taken out of Flosis must not put its tickets back in reach.
  test "a hidden project with Jira credentials offers no board" do
    @stub.update!(external_type: "jira", external_reference: "HID")

    get workshop_pipeline_path

    assert_response :success
    assert_no_match(/HID/, response.body)
  end

  test "the HR project form saves the flag" do
    patch project_path(@stub), params: { project: { show_in_workshop: "1" } }

    assert @stub.reload.show_in_workshop
  end

  test "the HR project form can take it away again" do
    @stub.update!(show_in_workshop: true)

    patch project_path(@stub), params: { project: { show_in_workshop: "0" } }

    assert_not @stub.reload.show_in_workshop
  end

  # Creating a project from inside Flosis and then not finding it there was the
  # obvious way to get this wrong.
  test "a project created from the Flosis dialog is visible in Flosis" do
    project = ProjectCreator.new(workspace: @workspace, attributes: { name: "Brand new" }).call

    assert project.show_in_workshop
  end

  test "but the dialog can still be told otherwise" do
    project = ProjectCreator.new(
      workspace: @workspace, attributes: { name: "Quiet one", show_in_workshop: false }
    ).call

    assert_not project.show_in_workshop
  end

  test "a project born in Time & HR is hidden until someone says otherwise" do
    project = @workspace.projects.create!(name: "Payroll", color: "#123456")

    assert_not project.show_in_workshop
  end
end
