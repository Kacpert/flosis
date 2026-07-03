require "test_helper"

class WorkshopLayoutTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true) # fixture default is false — required by require_workshop!
    sign_in_as(users(:one)) # admin/owner fixture (there is no users(:admin))
    post switch_product_path, params: { product: "workshop" }
  end

  test "workshop landing renders the Clar shell, not the HR shell" do
    get workshop_path
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

  test "clients get the Clar shell on the board but only the Jira Tasks nav item" do
    sign_in_as(users(:client_user))
    get jira_tasks_path
    assert_response :success
    assert_select "nav.clar-sidebar" do
      assert_select "a", text: /Create Tasks/, count: 0
      assert_select "a", text: /Configuration/, count: 0
    end
  end
end
