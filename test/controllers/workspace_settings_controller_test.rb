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

  test "admin can save GitHub settings; blank token keeps existing" do
    sign_in_as(users(:one))
    patch workspace_settings_path, params: { workspace: { github_token: "ghp_x", github_repo: "acme/widgets", pr_review_enabled: "1" } }
    @workspace.reload
    assert_equal "ghp_x", @workspace.github_token
    assert_equal "acme/widgets", @workspace.github_repo
    assert @workspace.pr_review_enabled

    patch workspace_settings_path, params: { workspace: { github_token: "", github_repo: "acme/other" } }
    @workspace.reload
    assert_equal "ghp_x", @workspace.github_token, "blank token keeps existing"
    assert_equal "acme/other", @workspace.github_repo
  end

  test "test_github runs a health check and stores the result" do
    @workspace.update!(github_token: "t", github_repo: "acme/widgets")
    fake = Object.new
    fake.define_singleton_method(:health_check) { { ok: false, error: "401 Unauthorized" } }
    orig = GithubClient.method(:for)
    GithubClient.define_singleton_method(:for) { |*_a, **_k| fake }
    sign_in_as(users(:one))
    post test_github_workspace_settings_path
    assert_redirected_to workspace_settings_path
    @workspace.reload
    assert_not @workspace.github_status_ok
    assert_equal "401 Unauthorized", @workspace.github_status_error
  ensure
    GithubClient.define_singleton_method(:for, orig)
  end

  test "employee cannot run test_github" do
    sign_in_as(users(:two))
    post test_github_workspace_settings_path
    assert_redirected_to root_path
  end
end
