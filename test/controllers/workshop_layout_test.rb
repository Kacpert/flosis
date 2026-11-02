require "test_helper"

class WorkshopLayoutTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true) # fixture default is false — required by require_workshop!
    sign_in_as(users(:one)) # admin/owner fixture (there is no users(:admin))
    post switch_product_path, params: { product: "workshop" }
  end

  test "workshop landing renders the Clar shell, not the HR shell" do
    get workshop_pipeline_path
    assert_response :success
    assert_select "div.clar-app"
    assert_select "header.clar-topbar"
    assert_select "nav.clar-sidebar"
    assert_select "header.m3-top-bar", count: 0
  end

  test "HR pages still render the M3 shell" do
    post switch_product_path, params: { product: "time_hr" }
    get time_entries_path
    assert_response :success
    assert_select "header.m3-top-bar"
    assert_select "div.clar-app", count: 0
  end

  # The Jira-only "client" role is retired: Tasks on its own now means the task
  # board and working on the ticket briefs, so both of those surfaces belong to
  # someone who holds nothing else — and nothing beyond them does.
  test "a person holding only Tasks gets the Clar shell and only the ticket surfaces" do
    sign_in_as(users(:client_user))
    get jira_tasks_path
    assert_response :success
    assert_select "div.clar-app"
    assert_select "nav.clar-sidebar" do
      assert_select "a span", text: "Jira Tasks", count: 1
      assert_select "a span", text: "Create Tasks", count: 1
      assert_select "a span", text: "Agents & Automations", count: 0
      assert_select "a span", text: "Reporting", count: 0
      assert_select "a span", text: "Configuration", count: 0
    end
  end
end
