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
end
