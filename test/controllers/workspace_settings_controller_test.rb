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

  test "admin can save Discord token and channel" do
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { discord_user_token: "tok-abc", discord_channel_id: "555" } }
    assert_redirected_to workspace_settings_path
    @workspace.reload
    assert_equal "tok-abc", @workspace.discord_user_token
    assert_equal "555", @workspace.discord_channel_id
  end

  test "saving with a blank token keeps the existing token" do
    @workspace.update!(discord_user_token: "keep-me", discord_channel_id: "555")
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { discord_user_token: "", discord_channel_id: "777" } }
    assert_redirected_to workspace_settings_path
    @workspace.reload
    assert_equal "keep-me", @workspace.discord_user_token, "blank token must not wipe the stored one"
    assert_equal "777", @workspace.discord_channel_id
  end
end
