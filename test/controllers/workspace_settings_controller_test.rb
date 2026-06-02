require "test_helper"

class WorkspaceSettingsControllerTest < ActionDispatch::IntegrationTest
  setup { @workspace = workspaces(:one) }

  test "admin can view workspace settings" do
    sign_in_as(users(:one)) # owner
    get workspace_settings_path
    assert_response :success
  end

  test "employee cannot view workspace settings" do
    sign_in_as(users(:two)) # employee
    get workspace_settings_path
    assert_redirected_to root_path
  end

  test "admin can enable the clients feature" do
    @workspace.update!(clients_enabled: false)
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { clients_enabled: "1" } }
    assert_redirected_to workspace_settings_path
    assert @workspace.reload.clients_enabled?
  end

  test "admin can disable the clients feature" do
    @workspace.update!(clients_enabled: true)
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { clients_enabled: "0" } }
    assert_redirected_to workspace_settings_path
    assert_not @workspace.reload.clients_enabled?
  end

  test "employee cannot change the clients feature" do
    @workspace.update!(clients_enabled: false)
    sign_in_as(users(:two))
    patch workspace_settings_path, params: { workspace: { clients_enabled: "1" } }
    assert_redirected_to root_path
    assert_not @workspace.reload.clients_enabled?
  end
end
