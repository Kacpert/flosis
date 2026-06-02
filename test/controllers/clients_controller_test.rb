require "test_helper"

class ClientsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    sign_in_as(users(:one)) # owner of workspace one
  end

  test "index redirects to root when the clients feature is disabled" do
    @workspace.update!(clients_enabled: false)
    get clients_path
    assert_redirected_to root_path
  end

  test "index renders when the clients feature is enabled" do
    @workspace.update!(clients_enabled: true)
    get clients_path
    assert_response :success
  end

  test "sidebar shows the Clients link when the feature is enabled for an admin" do
    @workspace.update!(clients_enabled: true)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", clients_path
  end

  test "sidebar hides the Clients link when the feature is disabled" do
    @workspace.update!(clients_enabled: false)
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", clients_path, count: 0
  end

  test "sidebar shows the Workspace Settings link for an admin" do
    sign_in_as(users(:one))
    get root_path
    assert_select "a[href=?]", workspace_settings_path
  end

  test "sidebar hides the Workspace Settings link for an employee" do
    sign_in_as(users(:two))
    get root_path
    assert_select "a[href=?]", workspace_settings_path, count: 0
  end
end
