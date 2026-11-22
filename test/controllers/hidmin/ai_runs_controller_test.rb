require "test_helper"

# SCRUM-70: a run that came back with no cost is flagged to Flosis staff until
# somebody has looked at it.
class Hidmin::AiRunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    users(:one).update!(flosis_staff: true)
    sign_in_as(users(:one))
  end

  def unknown_run!
    AiRun.create!(workspace: workspaces(:one), area: "agents", automation: "Rule", status: "succeeded", ran_at: Time.current)
  end

  test "looked at clears the unknown flag on the list" do
    first = unknown_run!
    unknown_run!
    get hidmin_workspaces_path
    assert_includes css_select("[data-organization-row='#{workspaces(:one).id}']").text, "2 UNKNOWN"

    patch looked_at_hidmin_ai_run_path(first)
    assert_redirected_to hidmin_workspace_path(workspaces(:one))
    first.reload
    assert first.unknown_reviewed_at
    assert_equal users(:one), first.unknown_reviewed_by

    get hidmin_workspaces_path
    assert_includes css_select("[data-organization-row='#{workspaces(:one).id}']").text, "1 UNKNOWN"
  end

  test "an organization's page lists its unknown runs with Looked at" do
    unknown_run!
    get hidmin_workspace_path(workspaces(:one))
    assert_select "[data-unknown-run] button", text: "Looked at"
  end
end
